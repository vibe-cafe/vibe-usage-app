import Foundation
import Testing
@testable import VibeUsage

/// The device sign-in shared by both panels and each Settings window
/// (`DeviceLinkFlow`). A fake server and a fake clock: no request, no browser,
/// no wait, and nothing is saved anywhere but in memory.
@MainActor
struct DeviceLinkFlowTests {
    nonisolated static let configured = UsageServer("https://configured.example")

    nonisolated static func device(
        code: String = "WDJB-MJHT", expiresIn: Int = 900, interval: Int = 5
    ) -> DeviceCodeResponse {
        DeviceCodeResponse(
            deviceCode: "device-\(code)", userCode: code,
            verificationUri: "https://configured.example/device",
            verificationUriComplete: "https://configured.example/device?code=\(code)",
            expiresIn: expiresIn, interval: interval
        )
    }

    nonisolated static func reply(apiKey: String? = nil, apiUrl: String? = nil, error: String? = nil) -> DevicePollResponse {
        DevicePollResponse(apiKey: apiKey, apiUrl: apiUrl, error: error)
    }

    /// Answers in order; an attempt with no answers left keeps waiting.
    final class FakeServer: @unchecked Sendable {
        private let lock = NSLock()
        private var codes: [Result<DeviceCodeResponse, Error>]
        private var replies: [Result<DevicePollResponse, Error>]
        private var clock = Date(timeIntervalSince1970: 1_800_000_000)
        private var _codeRequests: [(server: String, clientName: String, hostname: String?)] = []
        private var _polls: [String] = []
        private var _sleeps: [UInt64] = []
        private var _holdCodeRequest = false
        private var _holdPolls = false

        /// Holds a code request until the attempt is cancelled, then fails
        /// the way `URLSession` does.
        var holdCodeRequest: Bool {
            get { lock.withLock { _holdCodeRequest } }
            set { lock.withLock { _holdCodeRequest = newValue } }
        }

        /// Holds every wait between polls until the attempt is cancelled.
        var holdPolls: Bool {
            get { lock.withLock { _holdPolls } }
            set { lock.withLock { _holdPolls = newValue } }
        }

        init(codes: [Result<DeviceCodeResponse, Error>], replies: [Result<DevicePollResponse, Error>] = []) {
            self.codes = codes
            self.replies = replies
        }

        var codeRequests: [(server: String, clientName: String, hostname: String?)] { lock.withLock { _codeRequests } }
        var polls: [String] { lock.withLock { _polls } }
        var sleeps: [UInt64] { lock.withLock { _sleeps } }

        func requestCode(_ server: UsageServer, _ clientName: String, _ hostname: String?) async throws -> DeviceCodeResponse {
            let (hold, next): (Bool, Result<DeviceCodeResponse, Error>?) = lock.withLock {
                _codeRequests.append((server.baseURL, clientName, hostname))
                if _holdCodeRequest { return (true, nil) }
                return (false, codes.isEmpty ? nil : codes.removeFirst())
            }
            if hold {
                try? await Task.sleep(for: .seconds(3_600))
                throw URLError(.cancelled)
            }
            return try (next ?? .failure(URLError(.badServerResponse))).get()
        }

        func poll(_ server: UsageServer, _ deviceCode: String) async throws -> DevicePollResponse {
            let next: Result<DevicePollResponse, Error>? = lock.withLock {
                _polls.append(deviceCode)
                return replies.isEmpty ? nil : replies.removeFirst()
            }
            return try (next ?? .success(DeviceLinkFlowTests.reply(error: "authorization_pending"))).get()
        }

        /// Moves the clock by the wait instead of waiting.
        func sleep(_ nanoseconds: UInt64) async throws {
            let hold = lock.withLock {
                _sleeps.append(nanoseconds)
                clock = clock.addingTimeInterval(TimeInterval(nanoseconds) / 1_000_000_000)
                return _holdPolls
            }
            if hold { try await Task.sleep(for: .seconds(3_600)) }
            await Task.yield()
        }

        func now() -> Date { lock.withLock { clock } }
    }

    @MainActor
    final class Recorder {
        var opened: [URL] = []
        var saved: [(apiKey: String, server: String)] = []
        var serverReads = 0
        var phaseWhenSaved: DeviceLinkFlow.Phase?
        weak var flow: DeviceLinkFlow?
    }

    func makeFlow(_ fake: FakeServer, _ recorder: Recorder) -> DeviceLinkFlow {
        let service = DeviceLinkService(
            requestCode: { try await fake.requestCode($0, $1, $2) },
            poll: { try await fake.poll($0, $1) },
            sleep: { try await fake.sleep($0) },
            now: { fake.now() },
            openURL: { recorder.opened.append($0) },
            hostname: { "fixture-mac" }
        )
        let flow = DeviceLinkFlow(service: service) {
            recorder.serverReads += 1
            return Self.configured
        } save: { apiKey, server in
            recorder.phaseWhenSaved = recorder.flow?.phase
            recorder.saved.append((apiKey, server.baseURL))
        }
        recorder.flow = flow
        return flow
    }

    /// Lets the attempt run until `condition` holds (fails after ~2 s).
    func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<1_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    // MARK: Linking

    @Test func approvalSavesTheKeyWithTheServerItWasIssuedFor() async {
        let fake = FakeServer(
            codes: [.success(Self.device(interval: 0))],
            replies: [
                .success(Self.reply(error: "authorization_pending")),
                .failure(URLError(.networkConnectionLost)),  // a dropped poll is retried
                .success(Self.reply(error: nil)),
                .success(Self.reply(apiKey: "vbu_fixture", apiUrl: "https://linked.example")),
            ]
        )
        let recorder = Recorder()
        let flow = makeFlow(fake, recorder)

        flow.start()
        #expect(flow.phase == .requestingCode)
        #expect(flow.isRunning)
        await until { flow.phase == .idle }

        #expect(recorder.serverReads == 1)
        #expect(fake.codeRequests.map(\.server) == [Self.configured.baseURL])
        #expect(fake.codeRequests.first?.clientName == "\(AppConfig.displayName).app")
        #expect(fake.codeRequests.first?.hostname == "fixture-mac")
        #expect(recorder.opened.map(\.absoluteString) == ["https://configured.example/device?code=WDJB-MJHT"])
        // An interval below one second still waits one second.
        #expect(fake.sleeps == Array(repeating: 1_000_000_000, count: 4))
        #expect(fake.polls == Array(repeating: "device-WDJB-MJHT", count: 4))
        #expect(recorder.saved.map(\.apiKey) == ["vbu_fixture"])
        #expect(recorder.saved.map(\.server) == ["https://linked.example"])
        // The code stays on screen until the key is saved.
        #expect(recorder.phaseWhenSaved == .awaitingApproval(userCode: "WDJB-MJHT"))
        #expect(flow.failureReason == nil)
    }

    @Test func approvalWithoutAServerKeepsTheRequestingOne() async {
        let fake = FakeServer(codes: [.success(Self.device())], replies: [.success(Self.reply(apiKey: "vbu_fixture"))])
        let recorder = Recorder()
        let flow = makeFlow(fake, recorder)

        flow.start()
        await until { !recorder.saved.isEmpty && flow.phase == .idle }
        #expect(recorder.saved.map(\.server) == [Self.configured.baseURL])
        #expect(fake.sleeps == [5_000_000_000])
    }

    @Test func waitingShowsTheCodeToCompare() async {
        let fake = FakeServer(codes: [.success(Self.device(code: "ABCD-EFGH"))])
        fake.holdPolls = true
        let recorder = Recorder()
        let flow = makeFlow(fake, recorder)

        flow.start()
        await until { flow.userCode != nil }
        #expect(flow.phase == .awaitingApproval(userCode: "ABCD-EFGH"))
        #expect(flow.userCode == "ABCD-EFGH")
        #expect(flow.isRunning)
        flow.cancel()
    }

    // MARK: Endings

    @Test(arguments: [
        ("access_denied", "你拒绝了链接请求。"),
        ("expired_token", "验证码已过期，请重新登录。"),
        ("slow_down", "服务端返回未知错误：slow_down"),
    ])
    func aRefusalEndsTheAttemptWithItsReason(error: String, reason: String) async {
        let fake = FakeServer(codes: [.success(Self.device())], replies: [.success(Self.reply(error: error))])
        let recorder = Recorder()
        let flow = makeFlow(fake, recorder)

        flow.start()
        await until { flow.failureReason != nil }
        #expect(flow.phase == .failed(reason: reason))
        #expect(!flow.isRunning)
        #expect(flow.userCode == nil)
        #expect(fake.polls.count == 1)
        #expect(recorder.saved.isEmpty)
    }

    @Test func noCodeFromTheServerSaysSoWithoutOpeningTheBrowser() async {
        let failure = URLError(.notConnectedToInternet)
        let fake = FakeServer(codes: [.failure(failure)])
        let recorder = Recorder()
        let flow = makeFlow(fake, recorder)

        flow.start()
        await until { flow.failureReason != nil }
        #expect(flow.failureReason == "无法连接服务端：\(failure.localizedDescription)")
        #expect(recorder.opened.isEmpty)
        #expect(fake.polls.isEmpty)
    }

    @Test func theCodeExpiresAfterItsLifetime() async {
        let fake = FakeServer(codes: [.success(Self.device(expiresIn: 3, interval: 1))])
        let recorder = Recorder()
        let flow = makeFlow(fake, recorder)

        flow.start()
        await until { flow.failureReason != nil }
        #expect(flow.failureReason == "验证码已过期，请重新登录。")
        #expect(fake.polls.count == 3)
        #expect(recorder.saved.isEmpty)
    }

    @Test func aFailedAttemptCanStartOver() async {
        let fake = FakeServer(
            codes: [.success(Self.device()), .success(Self.device(code: "NEXT-CODE"))],
            replies: [.success(Self.reply(error: "expired_token"))]
        )
        let recorder = Recorder()
        let flow = makeFlow(fake, recorder)
        flow.start()
        await until { flow.failureReason != nil }

        fake.holdPolls = true
        flow.start()
        #expect(flow.phase == .requestingCode)
        #expect(flow.failureReason == nil)
        await until { flow.userCode == "NEXT-CODE" }
        // The server is read again for every attempt.
        #expect(recorder.serverReads == 2)
        flow.cancel()
    }

    // MARK: Cancel and repeat

    @Test func cancelStopsWaitingAndNothingIsSaved() async {
        let fake = FakeServer(codes: [.success(Self.device())], replies: [.success(Self.reply(apiKey: "vbu_fixture"))])
        fake.holdPolls = true
        let recorder = Recorder()
        let flow = makeFlow(fake, recorder)
        flow.start()
        await until { flow.userCode != nil }

        flow.cancel()
        #expect(flow.phase == .idle)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(flow.phase == .idle)
        #expect(fake.polls.isEmpty)
        #expect(recorder.saved.isEmpty)
    }

    /// Cancelling while the code request is in flight makes it fail (as
    /// `URLSession` does); that failure must not show, and must not touch the
    /// attempt started right after.
    @Test func aCancelledAttemptNeverWritesOverTheNextOne() async {
        let fake = FakeServer(codes: [.success(Self.device(code: "NEXT-CODE"))])
        fake.holdCodeRequest = true
        let recorder = Recorder()
        let flow = makeFlow(fake, recorder)
        flow.start()
        await until { fake.codeRequests.count == 1 }

        // The second attempt is still asking when the first one's failure
        // comes back.
        flow.cancel()
        flow.start()
        await until { fake.codeRequests.count == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(flow.phase == .requestingCode)
        #expect(flow.failureReason == nil)

        flow.cancel()
        fake.holdCodeRequest = false
        fake.holdPolls = true
        flow.start()
        await until { flow.userCode == "NEXT-CODE" }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(flow.phase == .awaitingApproval(userCode: "NEXT-CODE"))
        flow.cancel()
    }

    @Test func startWhileRunningIsIgnored() async {
        let fake = FakeServer(codes: [.success(Self.device())])
        fake.holdPolls = true
        let recorder = Recorder()
        let flow = makeFlow(fake, recorder)
        flow.start()
        flow.start()
        await until { flow.userCode != nil }
        flow.start()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(fake.codeRequests.count == 1)
        #expect(recorder.opened.count == 1)
        flow.cancel()
    }

    // MARK: Wiring

    /// Both panels read the one flow on `AppState`; each Settings window
    /// keeps its own, on the same service.
    @Test func panelsShareOneFlowAndSettingsKeepsItsOwn() {
        let suite = "DeviceLinkFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeServer(codes: [])
        let recorder = Recorder()
        let service = DeviceLinkService(
            requestCode: { try await fake.requestCode($0, $1, $2) },
            poll: { try await fake.poll($0, $1) },
            sleep: { try await fake.sleep($0) },
            now: { fake.now() },
            openURL: { recorder.opened.append($0) },
            hostname: { nil }
        )
        let state = AppState(
            initialConfig: nil, loadConfig: { nil },
            usageFetcher: { _, _, _ in throw URLError(.notConnectedToInternet) },
            quotaDefaults: defaults, zCodeAPIKeyStore: NoZCodeKeys(), quotaProductDiscoverer: { [] },
            interfaceStyle: InterfaceStylePreference(domain: suite, rollout: .externalTest),
            deviceLinkService: service
        )
        let flow = state.deviceLink
        state.interfaceStyle.select(.classic)
        #expect(state.deviceLink === flow)
        let settings = SettingsModel(appState: state)
        #expect(settings.relink !== state.deviceLink)
        #expect(settings.isRelinking == false)
        #expect(settings.relinkUserCode == nil)
        #expect(settings.relinkError == nil)
    }

    @Test func settingsForwardsItsFlow() async {
        let suite = "DeviceLinkFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeServer(codes: [.success(Self.device())], replies: [.success(Self.reply(error: "access_denied"))])
        let service = DeviceLinkService(
            requestCode: { try await fake.requestCode($0, $1, $2) },
            poll: { try await fake.poll($0, $1) },
            sleep: { try await fake.sleep($0) },
            now: { fake.now() },
            openURL: { _ in },
            hostname: { nil }
        )
        let state = AppState(
            initialConfig: nil, loadConfig: { nil },
            usageFetcher: { _, _, _ in throw URLError(.notConnectedToInternet) },
            quotaDefaults: defaults, zCodeAPIKeyStore: NoZCodeKeys(), quotaProductDiscoverer: { [] },
            interfaceStyle: InterfaceStylePreference(domain: suite, rollout: .externalTest),
            deviceLinkService: service
        )
        let settings = SettingsModel(appState: state)
        settings.startRelink()
        #expect(settings.isRelinking)
        await until { settings.relinkError != nil }
        #expect(settings.relinkError == "你拒绝了链接请求。")
        #expect(settings.isRelinking == false)
        // The panel's flow did not move.
        #expect(state.deviceLink.phase == .idle)
    }
}

private final class NoZCodeKeys: ZCodeAPIKeyStoring {
    func load(for region: ZCodeQuotaRegion) throws -> String? { nil }
    func store(_ value: String?, for region: ZCodeQuotaRegion) throws {}
}
