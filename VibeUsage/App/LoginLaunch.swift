import AppKit
import Network
import ServiceManagement

/// Whether this launch is macOS starting the app as a login item. Such a
/// launch behaves as any other on screen, but its network reads — the first
/// sync and every live quota read — wait until the user's proxy is up
/// (`waitForProxy`, at most two minutes), since the proxy client may not be
/// running yet right after login (network-privacy principle, workspace
/// AGENTS.md, rules 1, 2 and 6).
///
/// macOS marks a login-item launch on the open-application Apple Event
/// (`keyAELaunchedAsLogInItem`). Whether that mark is set for a
/// `SMAppService.mainApp` registration is not documented, so a launch with
/// the login item enabled within the first minutes after the system started
/// counts too.
enum LoginLaunch {
    static let bootWindow: TimeInterval = 300

    static func isLoginItemLaunch(
        event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent,
        loginItemEnabled: Bool = SMAppService.mainApp.status == .enabled,
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        if let event, event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
               == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        return loginItemEnabled && systemUptime < bootWindow
    }
}

extension LoginLaunch {
    /// The longest a login launch waits for the user's proxy before its
    /// first sync.
    static let proxyWaitLimit: TimeInterval = 120
    static let proxyPollInterval: TimeInterval = 2

    /// Waits until the system proxy the CLI would use for `url` accepts a
    /// connection (PAC included), at most `limit`. True when it came up,
    /// false at the limit. With no system proxy yet it keeps waiting: many
    /// proxy clients set the system proxy only once they have started, and
    /// whether this user relies on a proxy at all is not known here (that
    /// question is a separate change). A proxy that never answers just runs
    /// out the limit; requests sent to it afterwards fail instead of going
    /// direct.
    static func waitForProxy(
        url: URL,
        limit: TimeInterval = proxyWaitLimit,
        interval: TimeInterval = proxyPollInterval,
        route: @escaping @Sendable (URL) async -> SystemProxy.Route = { url in
            await SystemProxy.routes(for: [url]).first ?? .direct
        },
        accepts: @escaping @Sendable (String, Int) async -> Bool = LoginLaunch.accepts,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) async -> Bool {
        let deadline = now().addingTimeInterval(limit)
        while !Task.isCancelled {
            switch await route(url) {
            case let .http(host, port), let .socks(host, port):
                if await accepts(host, port) { return true }
            case .direct, .unresolved:
                break
            }
            if now() >= deadline { return false }
            await sleep(interval)
        }
        return false
    }

    /// Whether a TCP connection to `host:port` opens within a second.
    @Sendable static func accepts(_ host: String, _ port: Int) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let once = AcceptOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(true)
                case .failed, .waiting, .cancelled: once.finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { once.finish(false) }
            once.onFinish = { connection.cancel() }
        }
    }
}

private final class AcceptOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    var onFinish: (() -> Void)?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func finish(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let cleanup = onFinish
        lock.unlock()
        guard let pending else { return }
        cleanup?()
        pending.resume(returning: value)
    }
}
