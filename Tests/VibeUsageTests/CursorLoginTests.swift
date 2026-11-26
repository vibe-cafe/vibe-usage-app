import Foundation
import Testing
@testable import VibeUsage

/// The Cursor sign-in Vibe Usage keeps (`CursorLogin`). Fake store, fake CLI,
/// fake tokens: no Keychain, no CLI process, no network.
@MainActor
struct CursorLoginTests {
    // A made-up token: the app never parses it, it only travels on stdin.
    nonisolated static let fakeToken = "header.payload.signature"
    nonisolated static let start = Date(timeIntervalSince1970: 1_800_000_000)

    nonisolated static func credential(
        token: String = fakeToken, email: String? = "dev@example.com", expiresIn days: Double = 60
    ) -> Data {
        var object: [String: Any] = [
            "version": 1, "accessToken": token, "refreshToken": token, "userId": "user_fake",
            "obtainedAt": "2026-11-25T12:00:00.000Z",
            "expiresAt": iso(start.addingTimeInterval(days * 86_400)),
        ]
        if let email { object["email"] = email }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    nonisolated static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    final class MemoryStore: CursorLoginStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?
        var writes = 0
        init(_ value: Data? = nil) { self.value = value }
        var current: Data? { lock.withLock { value } }
        func load() throws -> Data? { lock.withLock { value } }
        func store(_ data: Data?) throws { lock.withLock { value = data; writes += 1 } }
    }

    final class FakeCLI: CursorLoginCLI, @unchecked Sendable {
        private let lock = NSLock()
        var versionAnswer: String? = "0.15.10"
        var signInAnswer: CursorSignInResult = .credential(CursorLoginTests.credential())
        var pageToOpen = URL(string: "https://cursor.com/loginDeepControl?challenge=c&uuid=u&mode=login&redirectTarget=cli")!
        var renewAnswer: CursorRenewalResult = .renewed(CursorLoginTests.credential(token: "renewed.token.value"))
        /// Lets a test hold a renewal open (concurrency).
        var renewGate: (() async -> Void)?
        private(set) var renewCalls: [Data] = []
        private(set) var versionCalls = 0

        func version() async -> String? {
            lock.withLock { versionCalls += 1 }
            return versionAnswer
        }

        func signIn(openBrowser: @escaping @Sendable (URL) -> Void) async -> CursorSignInResult {
            openBrowser(pageToOpen)
            return signInAnswer
        }

        func renew(_ credential: Data) async -> CursorRenewalResult {
            lock.withLock { renewCalls.append(credential) }
            await renewGate?()
            return renewAnswer
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private func login(
        store: MemoryStore = MemoryStore(), cli: FakeCLI = FakeCLI(), clock: Clock = Clock(start),
        opened: (@MainActor (URL) -> Void)? = nil
    ) -> CursorLogin {
        let login = CursorLogin(store: store, cli: cli, now: { clock.now }, openURL: opened ?? { _ in })
        login.load()
        return login
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Record

    @Test
    func recordKeepsWhatTheCLIPrintedAndReadsOnlyEmailAndExpiry() throws {
        let record = try #require(CursorLoginRecord.parse(Self.credential()))
        #expect(record.hasCredential)
        #expect(record.email == "dev@example.com")
        #expect(record.expiresAt == Self.start.addingTimeInterval(60 * 86_400))
        let object = try #require(try JSONSerialization.jsonObject(with: record.data) as? [String: Any])
        #expect(object["accessToken"] as? String == Self.fakeToken)
        #expect(object["userId"] as? String == "user_fake")
    }

    @Test
    func recordWithoutATokenOrAccountIsRefused() {
        #expect(CursorLoginRecord.parse(Data("{}".utf8)) == nil)
        #expect(CursorLoginRecord.parse(Data("not json".utf8)) == nil)
        #expect(CursorLoginRecord.parse(["accessToken": "x"]) == nil)
        #expect(CursorLoginRecord.parse(["userId": "u"]) == nil)
    }

    @Test
    func endedRecordKeepsOnlyTheEmail() throws {
        let ended = CursorLoginRecord.ended(email: "dev@example.com", at: Self.start)
        #expect(!ended.hasCredential)
        let reparsed = try #require(CursorLoginRecord.parse(ended.data))
        #expect(!reparsed.hasCredential)
        #expect(reparsed.email == "dev@example.com")
        let text = String(decoding: ended.data, as: UTF8.self)
        #expect(!text.contains("accessToken"))
    }

    // MARK: - What the app opens

    @Test
    func onlyCursorsSignInPageIsOpened() {
        let good = "https://cursor.com/loginDeepControl?challenge=abc&uuid=1&mode=login&redirectTarget=cli"
        #expect(CursorLogin.signInPage(good)?.absoluteString == good)
        for bad in [
            "http://cursor.com/loginDeepControl?challenge=abc",
            "https://cursor.com.example.net/loginDeepControl",
            "https://www.cursor.com/loginDeepControl",
            "https://cursor.com:8443/loginDeepControl",
            "https://user@cursor.com/loginDeepControl",
            "https://cursor.com/loginDeepControl/extra",
            "https://cursor.com/settings",
            "file:///tmp/loginDeepControl",
            "javascript:alert(1)",
        ] {
            #expect(CursorLogin.signInPage(bad) == nil, "\(bad)")
        }
    }

    @Test
    func signInNeedsCLI0_15_10OrNewer() {
        #expect(!CursorLogin.supportsSignIn(version: "0.15.9"))
        #expect(!CursorLogin.supportsSignIn(version: "0.14.99"))
        #expect(CursorLogin.supportsSignIn(version: "0.15.10"))
        #expect(CursorLogin.supportsSignIn(version: "0.15.11"))
        #expect(CursorLogin.supportsSignIn(version: "0.16.0"))
        #expect(CursorLogin.supportsSignIn(version: "1.0"))
    }

    @Test
    func rowAppearsOnlyOnceTheCLIHasTheCommand() async {
        let cli = FakeCLI()
        cli.versionAnswer = "0.15.9"
        let login = login(cli: cli)
        #expect(!login.isAvailable)
        await login.checkCLISupport()
        #expect(login.cliSupportsSignIn == false)
        #expect(!login.isAvailable)
        // Asked again only after a minute.
        cli.versionAnswer = "0.15.10"
        await login.checkCLISupport()
        #expect(cli.versionCalls == 1)
        // A quota answer carrying `signIn` proves it.
        login.noteCLISupportsSignIn()
        #expect(login.isAvailable)
        #expect(login.needsSignIn)
    }

    @Test
    func anExistingSignInIsShownWhateverTheCLI() {
        let login = login(store: MemoryStore(Self.credential()))
        #expect(login.isAvailable)
        #expect(login.phase == .signedIn(email: "dev@example.com"))
        #expect(!login.needsSignIn)
    }

    // MARK: - Sign-in and sign-out

    @Test
    func signInOpensTheCLIsPageAndKeepsTheCredential() async throws {
        let store = MemoryStore()
        let cli = FakeCLI()
        var opened: [URL] = []
        var changes: [Bool] = []
        let login = login(store: store, cli: cli, opened: { opened.append($0) })
        login.onAccountChange = { changes.append($0) }
        login.noteCLISupportsSignIn()
        login.signIn()
        #expect(login.phase == .waiting)
        await waitUntil { login.phase != .waiting && !changes.isEmpty }
        #expect(login.phase == .signedIn(email: "dev@example.com"))
        #expect(opened == [cli.pageToOpen])
        #expect(changes == [true])
        #expect(store.current == CursorLoginRecord.parse(Self.credential())?.data)
        #expect(login.errorText == nil)
    }

    @Test
    func failedSignInSaysWhyAndKeepsNothing() async {
        let store = MemoryStore()
        let cli = FakeCLI()
        cli.signInAnswer = .failed(.timedOut)
        let login = login(store: store, cli: cli)
        login.noteCLISupportsSignIn()
        login.signIn()
        await waitUntil { login.phase != .waiting }
        #expect(login.phase == .signedOut)
        #expect(login.errorText == "5 分钟内没有确认，已取消")
        #expect(store.current == nil)
    }

    @Test
    func signInFailureCodesMapToOurOwnCopy() {
        #expect(ProcessCursorLoginCLI.failure(code: "timeout") == .timedOut)
        #expect(ProcessCursorLoginCLI.failure(code: "network") == .network)
        #expect(ProcessCursorLoginCLI.failure(code: "proxy") == .proxy)
        #expect(ProcessCursorLoginCLI.failure(code: "failed") == .failed)
        #expect(ProcessCursorLoginCLI.failure(code: nil) == .failed)
    }

    @Test
    func cliEventsAreReadWithoutKeepingTheirText() throws {
        let open = try #require(ProcessCursorLoginCLI.Event(line: #"{"event":"open","url":"https://cursor.com/loginDeepControl?x=1"}"#))
        #expect(open.event == "open")
        #expect(open.url == "https://cursor.com/loginDeepControl?x=1")
        let credential = try #require(ProcessCursorLoginCLI.Event(line: String(decoding: try JSONSerialization.data(
            withJSONObject: ["event": "credential", "credential": try JSONSerialization.jsonObject(with: Self.credential())]
        ), as: UTF8.self)))
        #expect(CursorLoginRecord.parse(try #require(credential.credential))?.email == "dev@example.com")
        let error = try #require(ProcessCursorLoginCLI.Event(line: #"{"event":"error","code":"proxy","message":"free text"}"#))
        #expect(error.code == "proxy")
        #expect(ProcessCursorLoginCLI.Event(line: "请在浏览器里确认登录 Cursor") == nil)
    }

    @Test
    func signOutForgetsTheSignIn() async {
        let store = MemoryStore(Self.credential())
        var changes: [Bool] = []
        let login = login(store: store)
        login.onAccountChange = { changes.append($0) }
        login.signOut()
        #expect(login.phase == .signedOut)
        #expect(store.current == nil)
        await waitUntil { !changes.isEmpty }
        #expect(changes == [false])
    }

    // MARK: - Renewal

    @Test
    func aSignInFarFromExpiryIsHandedOverAsIs() async {
        let cli = FakeCLI()
        let login = login(store: MemoryStore(Self.credential(expiresIn: 30)), cli: cli)
        let record = await login.credentialForCLI()
        #expect(record?.data == CursorLoginRecord.parse(Self.credential(expiresIn: 30))?.data)
        #expect(cli.renewCalls.isEmpty)
    }

    @Test
    func withinSevenDaysItIsRenewedFirstAndTheNewOneKept() async throws {
        let store = MemoryStore(Self.credential(expiresIn: 6))
        let cli = FakeCLI()
        let login = login(store: store, cli: cli)
        let record = try #require(await login.credentialForCLI())
        #expect(cli.renewCalls.count == 1)
        #expect(cli.renewCalls.first == CursorLoginRecord.parse(Self.credential(expiresIn: 6))?.data)
        let renewed = CursorLoginRecord.parse(Self.credential(token: "renewed.token.value"))
        #expect(record.data == renewed?.data)
        #expect(store.current == renewed?.data)
        #expect(login.phase == .signedIn(email: "dev@example.com"))
    }

    @Test
    func cursorEndingTheSignInIsRecordedWithoutTheTokens() async throws {
        let store = MemoryStore(Self.credential(expiresIn: 2))
        let cli = FakeCLI()
        cli.renewAnswer = .expired
        let login = login(store: store, cli: cli)
        #expect(await login.credentialForCLI() == nil)
        #expect(login.phase == .expired(email: "dev@example.com"))
        #expect(login.hasEnded)
        #expect(login.needsSignIn)
        let kept = String(decoding: try #require(store.current), as: UTF8.self)
        #expect(!kept.contains(Self.fakeToken))
        // Nothing more is handed to the CLI.
        #expect(await login.credentialForCLI() == nil)
        #expect(cli.renewCalls.count == 1)
    }

    @Test
    func anIncompleteRenewalWaitsSixHoursAndKeepsTheCurrentOne() async throws {
        let clock = Clock(Self.start)
        let cli = FakeCLI()
        cli.renewAnswer = .incomplete
        let login = login(store: MemoryStore(Self.credential(expiresIn: 3)), cli: cli, clock: clock)
        let current = CursorLoginRecord.parse(Self.credential(expiresIn: 3))
        #expect(await login.credentialForCLI() == current)
        #expect(await login.credentialForCLI() == current)
        #expect(cli.renewCalls.count == 1)
        clock.advance(6 * 3600 + 1)
        cli.renewAnswer = .renewed(Self.credential(token: "renewed.token.value", expiresIn: 60))
        #expect(await login.credentialForCLI()?.data == CursorLoginRecord.parse(Self.credential(token: "renewed.token.value"))?.data)
        #expect(cli.renewCalls.count == 2)
    }

    @Test
    func concurrentRunsShareOneRenewal() async {
        let cli = FakeCLI()
        let gate = AsyncGate()
        cli.renewGate = { await gate.wait() }
        let login = login(store: MemoryStore(Self.credential(expiresIn: 1)), cli: cli)
        async let first = login.credentialForCLI()
        async let second = login.credentialForCLI()
        await waitUntil { cli.renewCalls.count == 1 }
        await gate.open()
        let results = await [first, second]
        #expect(cli.renewCalls.count == 1)
        #expect(results[0] == results[1])
        #expect(results[0]?.data == CursorLoginRecord.parse(Self.credential(token: "renewed.token.value"))?.data)
    }

    @Test
    func signingOutDuringARenewalDropsTheRenewedToken() async {
        let store = MemoryStore(Self.credential(expiresIn: 1))
        let cli = FakeCLI()
        let gate = AsyncGate()
        cli.renewGate = { await gate.wait() }
        let login = login(store: store, cli: cli)
        async let pending = login.credentialForCLI()
        await waitUntil { cli.renewCalls.count == 1 }
        login.signOut()
        await gate.open()
        #expect(await pending == nil)
        #expect(store.current == nil)
        #expect(login.phase == .signedOut)
    }

    @Test
    func aRejectedSignInIsRenewedOnceThenEnded() async {
        let store = MemoryStore(Self.credential())
        let cli = FakeCLI()
        let login = login(store: store, cli: cli)
        let passed = try! #require(await login.credentialForCLI())
        // Renewed: the caller reads again with the new one.
        let renewed = CursorLoginRecord.parse(Self.credential(token: "renewed.token.value"))!
        #expect(await login.renewAfterRejection(of: passed) == .renewed(renewed))
        // Renewed meanwhile by another run: no second request.
        #expect(await login.renewAfterRejection(of: passed) == .renewed(renewed))
        #expect(cli.renewCalls.count == 1)
        // Cursor ends it.
        cli.renewAnswer = .expired
        #expect(await login.renewAfterRejection(of: renewed) == .ended)
        #expect(login.phase == .expired(email: "dev@example.com"))
        #expect(await login.renewAfterRejection(of: renewed) == .ended)
        #expect(cli.renewCalls.count == 2)
    }

    @Test
    func settingsOpensTheBlockOnlyWhenASignInIsMissing() {
        let login = login()
        login.noteCLISupportsSignIn()
        let suite = "CursorLoginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(quotaDefaults: defaults, cursorLogin: login)
        // Cursor's own login still reads: no push toward signing in.
        #expect(!appState.cursorSignInNeeded)
        appState.rateLimits = [ProviderRateLimit(provider: .cursor, status: .noData, fetchedAt: Date(),
                                                 liveFailure: .signInRequired)]
        #expect(appState.cursorSignInNeeded)
        let ended = self.login(store: MemoryStore(CursorLoginRecord.ended(email: nil, at: Self.start).data))
        #expect(AppState(quotaDefaults: defaults, cursorLogin: ended).cursorSignInNeeded)
    }

    @Test
    func aLapsedSignInShowsAsExpired() {
        let login = login(store: MemoryStore(Self.credential(expiresIn: -1)))
        #expect(login.phase == .expired(email: "dev@example.com"))
        #expect(!login.hasEnded)
    }
}

/// Holds async work until opened.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
