import Foundation
import Network
import Security

/// Lets the Claude probe follow a SOCKS-only system proxy. Claude Code
/// speaks only HTTP proxies, so with a SOCKS proxy it used to connect
/// directly with the user's Claude login (network-privacy principle,
/// workspace AGENTS.md, rules 1, 2 and 6).
///
/// A small HTTP `CONNECT` relay that exists only while one probe runs:
///
/// - **Where it listens:** 127.0.0.1 only, on a port the system picks.
/// - **Who can connect:** processes on this Mac that present the random
///   credential made for this relay (`Proxy-Authorization`, handed to Claude
///   Code inside `HTTPS_PROXY`). Anything else gets `407`.
/// - **What it carries:** `CONNECT` to Anthropic's and Claude's own hosts on
///   port 443 (`allowedDomains`), nothing else (`403` / `405`). It never sees
///   inside TLS: bytes are copied as they are.
/// - **Where it sends them:** the route resolved for that host when the
///   probe started (`SystemProxy.claudeLaunch` keeps them for the whole
///   probe, so a proxy client restarting mid-probe cannot turn a connection
///   direct): a SOCKS proxy gets a SOCKS5 handshake with the host *name*,
///   never a locally resolved address; an HTTP proxy gets the `CONNECT`
///   chained; a host the PAC sends direct (the user's own rule) connects
///   directly; an unresolvable route is refused (`502`), never sent direct.
/// - **When it runs:** started by `ClaudeUsageProbe.fetch` when the system
///   routes Anthropic's hosts through SOCKS only, stopped (listener and every
///   connection) as soon as that probe finishes.
final class ClaudeSOCKSRelay: @unchecked Sendable {
    static let allowedDomains = ["anthropic.com", "claude.com", "claude.ai"]
    static let user = "vibe-usage"
    private static let headerLimit = 8 * 1024

    let port: UInt16
    let token: String
    private let listener: NWListener
    private let queue: DispatchQueue
    private let route: @Sendable (URL) async -> SystemProxy.Route
    private let lock = NSLock()
    private var open: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false

    /// `HTTPS_PROXY` / `HTTP_PROXY` value for the child.
    var proxyURL: String { "http://\(Self.user):\(token)@127.0.0.1:\(port)" }

    private init(listener: NWListener, port: UInt16, token: String, queue: DispatchQueue,
                 route: @escaping @Sendable (URL) async -> SystemProxy.Route) {
        self.listener = listener
        self.port = port
        self.token = token
        self.queue = queue
        self.route = route
    }

    /// Starts a relay on 127.0.0.1. `route` answers where a host's traffic
    /// goes (the live system route by default).
    static func start(
        route: @escaping @Sendable (URL) async -> SystemProxy.Route = { url in
            await SystemProxy.routes(for: [url]).first ?? .unresolved
        }
    ) async throws -> ClaudeSOCKSRelay {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "claude-socks-relay")
        let token = randomToken()
        let holder = RelayHolder()
        listener.newConnectionHandler = { connection in holder.relay?.accept(connection) ?? connection.cancel() }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { once.run { continuation.resume(returning: port) } }
                case let .failed(error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let relay = ClaudeSOCKSRelay(listener: listener, port: port, token: token, queue: queue, route: route)
        holder.relay = relay
        return relay
    }

    /// Closes the listener and every connection it carries.
    func stop() {
        lock.lock()
        stopped = true
        let connections = Array(open.values)
        open.removeAll()
        lock.unlock()
        listener.cancel()
        connections.forEach { $0.cancel() }
    }

    static func isAllowed(host: String, port: Int) -> Bool {
        guard port == 443 else { return false }
        let name = host.lowercased()
        return allowedDomains.contains { name == $0 || name.hasSuffix(".\($0)") }
    }

    // MARK: - Connections

    private func track(_ connection: NWConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return false }
        open[ObjectIdentifier(connection)] = connection
        return true
    }

    private func forget(_ connection: NWConnection) {
        lock.lock()
        open[ObjectIdentifier(connection)] = nil
        lock.unlock()
    }

    private func close(_ connections: NWConnection...) {
        for connection in connections {
            forget(connection)
            connection.cancel()
        }
    }

    private func accept(_ client: NWConnection) {
        guard track(client) else { client.cancel(); return }
        client.start(queue: queue)
        readHeader(client, buffered: Data()) { [weak self] header, rest in
            guard let self else { return }
            guard let header else { self.close(client); return }
            self.handle(client, header: header, rest: rest)
        }
    }

    private func readHeader(_ connection: NWConnection, buffered: Data,
                            done: @escaping @Sendable (String?, Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headerLimit) { [weak self] data, _, complete, error in
            var buffer = buffered
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                done(String(data: buffer[..<end.lowerBound], encoding: .utf8), Data(buffer[end.upperBound...]))
            } else if error != nil || complete || buffer.count >= Self.headerLimit {
                done(nil, Data())
            } else {
                self?.readHeader(connection, buffered: buffer, done: done)
            }
        }
    }

    private func reply(_ client: NWConnection, _ status: String, then: (@Sendable () -> Void)? = nil) {
        let body = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        client.send(content: Data(body.utf8), completion: .contentProcessed { [weak self] _ in
            if let then { then() } else { self?.close(client) }
        })
    }

    private func handle(_ client: NWConnection, header: String, rest: Data) {
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[0] == "CONNECT" else { reply(client, "405 Method Not Allowed"); return }
        let expected = "Basic " + Data("\(Self.user):\(token)".utf8).base64EncodedString()
        let authorized = lines.dropFirst().contains { line in
            guard let colon = line.firstIndex(of: ":") else { return false }
            return line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "proxy-authorization"
                && line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) == expected
        }
        guard authorized else {
            reply(client, "407 Proxy Authentication Required")
            return
        }
        let target = String(parts[1])
        guard let colon = target.lastIndex(of: ":"), let port = Int(target[target.index(after: colon)...]) else {
            reply(client, "400 Bad Request")
            return
        }
        let host = String(target[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard Self.isAllowed(host: host, port: port), let url = URL(string: "https://\(host):\(port)/") else {
            reply(client, "403 Forbidden")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let route = await self.route(url)
            self.open(client, host: host, port: port, route: route, rest: rest)
        }
    }

    private func open(_ client: NWConnection, host: String, port: Int, route: SystemProxy.Route, rest: Data) {
        let upstream: NWConnection
        switch route {
        case let .socks(proxyHost, proxyPort), let .http(proxyHost, proxyPort):
            guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: proxyPort)) else {
                reply(client, "502 Bad Gateway"); return
            }
            upstream = NWConnection(host: NWEndpoint.Host(proxyHost), port: endpointPort, using: .tcp)
        case .direct:
            // The user's own rule sends this host direct.
            upstream = NWConnection(host: NWEndpoint.Host(host),
                                    port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 443, using: .tcp)
        case .unresolved:
            reply(client, "502 Bad Gateway"); return
        }
        guard track(upstream) else { close(client); upstream.cancel(); return }
        let once = Once()
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                once.run {
                    self.handshake(upstream, route: route, host: host, port: port) { ok in
                        guard ok else { self.close(upstream); self.reply(client, "502 Bad Gateway"); return }
                        self.reply(client, "200 Connection Established") {
                            if !rest.isEmpty { upstream.send(content: rest, completion: .contentProcessed { _ in }) }
                            self.pipe(from: client, to: upstream)
                            self.pipe(from: upstream, to: client)
                        }
                    }
                }
            case .failed, .waiting:
                once.run { self.close(upstream); self.reply(client, "502 Bad Gateway") }
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    private func handshake(_ upstream: NWConnection, route: SystemProxy.Route, host: String, port: Int,
                           done: @escaping @Sendable (Bool) -> Void) {
        switch route {
        case .socks: socks5(upstream, host: host, port: port, done: done)
        case .http: chainedConnect(upstream, host: host, port: port, done: done)
        case .direct: done(true)
        case .unresolved: done(false)
        }
    }

    /// SOCKS5, no authentication, the host by name (ATYP 3).
    private func socks5(_ upstream: NWConnection, host: String, port: Int, done: @escaping @Sendable (Bool) -> Void) {
        let name = Data(host.utf8)
        guard name.count <= 255 else { done(false); return }
        upstream.send(content: Data([5, 1, 0]), completion: .contentProcessed { _ in })
        exact(upstream, 2) { [weak self] greeting in
            guard let self, greeting == Data([5, 0]) else { done(false); return }
            var request = Data([5, 1, 0, 3, UInt8(name.count)])
            request.append(name)
            request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xff)])
            upstream.send(content: request, completion: .contentProcessed { _ in })
            self.exact(upstream, 4) { head in
                guard let head, head.count == 4, head[0] == 5, head[1] == 0 else { done(false); return }
                switch head[3] {
                case 1: self.exact(upstream, 6) { done($0 != nil) }
                case 4: self.exact(upstream, 18) { done($0 != nil) }
                case 3:
                    self.exact(upstream, 1) { length in
                        guard let length, let count = length.first else { done(false); return }
                        self.exact(upstream, Int(count) + 2) { done($0 != nil) }
                    }
                default: done(false)
                }
            }
        }
    }

    /// The same `CONNECT`, one hop further, to an HTTP proxy.
    private func chainedConnect(_ upstream: NWConnection, host: String, port: Int, done: @escaping @Sendable (Bool) -> Void) {
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n"
        upstream.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        readHeader(upstream, buffered: Data()) { header, _ in
            let status = header?.split(separator: " ").dropFirst().first
            done(status == "200")
        }
    }

    private func exact(_ connection: NWConnection, _ count: Int, done: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            done(error == nil && data?.count == count ? data : nil)
        }
    }

    private func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil { self.close(source, destination); return }
                    if complete || error != nil { self.close(source, destination) } else { self.pipe(from: source, to: destination) }
                })
            } else if complete || error != nil {
                self.close(source, destination)
            } else {
                self.pipe(from: source, to: destination)
            }
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private final class RelayHolder: @unchecked Sendable {
    weak var relay: ClaudeSOCKSRelay?
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
