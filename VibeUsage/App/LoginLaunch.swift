import AppKit
import Network
import ServiceManagement

/// Whether this launch is macOS starting the app as a login item. Such a
/// launch behaves as any other on screen, but when a proxy is configured its
/// dashboard reads, sync and live quota reads wait until that
/// proxy accepts connections (`waitForProxy`, at most two minutes), since the
/// proxy client may not be running yet right after login (network-privacy
/// principle, workspace AGENTS.md, rules 1, 2 and 6). With no proxy
/// configured nothing waits: a vendor read that would go out direct is gated
/// by the egress check instead (`EgressCheck`, rule 3).
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
    /// network reads (sync, dashboard, live quotas) go ahead.
    static let proxyWaitLimit: TimeInterval = 120
    static let proxyPollInterval: TimeInterval = 2

    /// The URLs whose routes tell whether the user's proxy is up: the sync
    /// server and every host the app and the CLI read. A PAC often sends the
    /// sync server direct and only the vendors through the proxy.
    static func proxyProbeURLs(server: URL) -> [URL] {
        var hosts: [String] = []
        for host in SystemProxy.claudeHosts + ["chatgpt.com"] + SystemProxy.cliHosts where !hosts.contains(host) {
            hosts.append(host)
        }
        return [server] + hosts.compactMap { URL(string: "https://\($0)/") }
    }

    /// Waits until the system route (PAC included) of any of `urls` points at
    /// a proxy that accepts a connection, at most `limit`. True when one came
    /// up or when no proxy is configured at all (every route direct: nothing
    /// to wait for), false at the limit. A PAC that cannot be evaluated yet
    /// counts as configured (the proxy client often serves the PAC itself). A
    /// proxy variable in the app's own environment does not count: the app's
    /// own requests (Codex, OpenCode Go) follow the system settings only.
    /// Before 2026-11-24 a launch with no proxy waited the full two minutes,
    /// since some proxy clients set the system proxy only once started; now
    /// such a launch goes ahead at once and the vendor reads that would go
    /// out direct pause on a wrong egress (`EgressCheck`) until a later read
    /// sees the proxy. A proxy that never answers just runs out the limit;
    /// requests sent to it afterwards fail instead of going direct.
    static func waitForProxy(
        urls: [URL],
        limit: TimeInterval = proxyWaitLimit,
        interval: TimeInterval = proxyPollInterval,
        routes: @escaping @Sendable ([URL]) async -> [SystemProxy.Route] = { urls in
            await SystemProxy.routes(for: urls)
        },
        accepts: @escaping @Sendable (String, Int) async -> Bool = LoginLaunch.accepts,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) async -> Bool {
        let deadline = now().addingTimeInterval(limit)
        while !Task.isCancelled {
            var endpoints: [(String, Int)] = []
            var unresolved = false
            for route in await routes(urls) {
                switch route {
                case let .http(host, port), let .socks(host, port):
                    if !endpoints.contains(where: { $0 == (host, port) }) { endpoints.append((host, port)) }
                case .unresolved:
                    unresolved = true
                case .direct:
                    break
                }
            }
            if endpoints.isEmpty, !unresolved { return true }
            for (host, port) in endpoints where await accepts(host, port) { return true }
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
            let once = AcceptOnce(continuation) { connection.cancel() }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(true)
                case .failed, .waiting, .cancelled: once.finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { once.finish(false) }
        }
    }
}

private final class AcceptOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private let cleanup: @Sendable () -> Void

    init(_ continuation: CheckedContinuation<Bool, Never>, cleanup: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.cleanup = cleanup
    }

    func finish(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        cleanup()
        pending.resume(returning: value)
    }
}
