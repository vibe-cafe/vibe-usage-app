import AppKit
import Foundation
import Observation

/// What the device sign-in reaches outside the app. A seam so tests never
/// reach a server, open the browser or wait out a poll interval.
struct DeviceLinkService: Sendable {
    /// `POST /api/usage/device/code` on the configured server.
    var requestCode: @Sendable (_ server: UsageServer, _ clientName: String, _ hostname: String?) async throws
        -> DeviceCodeResponse
    /// `POST /api/usage/device/poll`.
    var poll: @Sendable (_ server: UsageServer, _ deviceCode: String) async throws -> DevicePollResponse
    /// The wait between polls; throws when the sign-in is cancelled.
    var sleep: @Sendable (_ nanoseconds: UInt64) async throws -> Void
    var now: @Sendable () -> Date
    var openURL: @MainActor @Sendable (URL) -> Void
    /// The name the server lists the device under.
    var hostname: @MainActor @Sendable () -> String?

    static let live = DeviceLinkService(
        requestCode: { try await requestDeviceCode(server: $0, clientName: $1, hostname: $2) },
        poll: { try await pollDeviceCode(server: $0, deviceCode: $1) },
        sleep: { try await Task.sleep(nanoseconds: $0) },
        now: { Date() },
        openURL: { _ = NSWorkspace.shared.open($0) },
        hostname: { Host.current().localizedName?.replacingOccurrences(of: ".local", with: "") }
    )
}

/// Links this Mac to a Vibe Usage account with the device flow: ask the
/// server for a code, open the approval page in the browser, poll until the
/// user approves there, then save the key it returns.
///
/// The panel keeps one (`AppState.deviceLink`), shared by the classic panel
/// and the new one, so it survives closing the panel and switching the style.
/// Each Settings window keeps its own for 「链接」 / 「重新链接」.
@MainActor
@Observable
final class DeviceLinkFlow {
    enum Phase: Equatable {
        /// Nothing in flight (「登录并链接数据」).
        case idle
        /// Asking the server for a code.
        case requestingCode
        /// The approval page is open; the user compares the code there and
        /// confirms. Stays until the returned key is saved.
        case awaitingApproval(userCode: String)
        /// The last attempt ended without a link (「登录没成功」).
        case failed(reason: String)
    }

    private(set) var phase: Phase = .idle

    @ObservationIgnored private let service: DeviceLinkService
    @ObservationIgnored private let server: @MainActor () -> UsageServer
    @ObservationIgnored private let save: @MainActor (_ apiKey: String, _ server: UsageServer) async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Changes on every start and cancel, so an attempt that was cancelled
    /// never writes over the one that replaced it.
    @ObservationIgnored private var attempt = 0

    /// - Parameters:
    ///   - server: The server to link with, read when an attempt starts.
    ///   - save: Stores the approved key and the server it belongs to.
    init(
        service: DeviceLinkService = .live,
        server: @escaping @MainActor () -> UsageServer,
        save: @escaping @MainActor (_ apiKey: String, _ server: UsageServer) async -> Void
    ) {
        self.service = service
        self.server = server
        self.save = save
    }

    var isRunning: Bool {
        switch phase {
        case .requestingCode, .awaitingApproval: true
        case .idle, .failed: false
        }
    }

    /// The code to compare with the browser while it waits.
    var userCode: String? {
        if case .awaitingApproval(let code) = phase { return code }
        return nil
    }

    var failureReason: String? {
        if case .failed(let reason) = phase { return reason }
        return nil
    }

    /// Starts an attempt; ignored while one is running.
    func start() {
        guard !isRunning else { return }
        attempt &+= 1
        let current = attempt
        phase = .requestingCode
        task = Task { await self.run(current) }
    }

    /// Stops the attempt in flight so the user can start over at once
    /// instead of waiting out the code's expiry.
    func cancel() {
        task?.cancel()
        task = nil
        attempt &+= 1
        phase = .idle
    }

    private func run(_ current: Int) async {
        let server = server()
        let device: DeviceCodeResponse
        do {
            device = try await service.requestCode(server, "\(AppConfig.displayName).app", service.hostname())
        } catch {
            finish(current, .failed(reason: "无法连接服务端：\(error.localizedDescription)"))
            return
        }
        guard current == attempt else { return }

        phase = .awaitingApproval(userCode: device.userCode)
        if let url = server.verificationURL(device.verificationUriComplete) {
            service.openURL(url)
        }

        let interval = UInt64(max(device.interval, 1)) * 1_000_000_000
        let deadline = service.now().addingTimeInterval(TimeInterval(device.expiresIn))

        while service.now() < deadline {
            if Task.isCancelled { return }
            try? await service.sleep(interval)
            if Task.isCancelled { return }
            let reply: DevicePollResponse
            do {
                reply = try await service.poll(server, device.deviceCode)
            } catch {
                // A dropped poll is retried at the next interval.
                continue
            }
            // Cancelled (or started over) while this poll was out: whatever
            // it brings back, an approval included, is dropped, never saved.
            guard current == attempt else { return }
            if let apiKey = reply.apiKey {
                await save(apiKey, reply.linkedServer(fallingBackTo: server))
                finish(current, .idle)
                return
            }
            switch reply.error {
            case "authorization_pending", nil:
                continue
            case "access_denied":
                finish(current, .failed(reason: DeviceFlowError.denied.localizedDescription))
                return
            case "expired_token":
                finish(current, .failed(reason: DeviceFlowError.expired.localizedDescription))
                return
            default:
                finish(current, .failed(reason: "服务端返回未知错误：\(reply.error ?? "unknown")"))
                return
            }
        }
        finish(current, .failed(reason: DeviceFlowError.expired.localizedDescription))
    }

    private func finish(_ current: Int, _ phase: Phase) {
        guard current == attempt else { return }
        self.phase = phase
        task = nil
    }
}

extension AppState {
    /// A device sign-in that links this app: the server comes from the config
    /// read again at the start, and an approved key is saved with its server
    /// (which starts the sync schedule) before usage is fetched. `afterSave`
    /// runs once that is done.
    func makeDeviceLink(afterSave: (@MainActor () -> Void)? = nil) -> DeviceLinkFlow {
        DeviceLinkFlow(service: deviceLinkService) { [weak self] in
            guard let self else { return UsageServer(nil) }
            self.reloadConfig()
            return self.usageServer
        } save: { [weak self] apiKey, server in
            guard let self else { return }
            self.configure(apiKey: apiKey, server: server)
            await self.fetchUsageData()
            afterSave?()
        }
    }
}
