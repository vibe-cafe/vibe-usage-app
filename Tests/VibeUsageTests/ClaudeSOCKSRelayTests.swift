import Foundation
import Network
import Testing
@testable import VibeUsage

/// `ClaudeSOCKSRelay` lets the Claude probe follow a SOCKS-only system proxy.
/// Everything here runs on 127.0.0.1 against stand-ins: a SOCKS5 server that
/// forwards to a local echo server. Nothing leaves the machine.
struct ClaudeSOCKSRelayTests {

    @Test
    func tunnelsThroughSOCKSWithTheHostName() async throws {
        let echo = try await LocalServer.echo()
        defer { echo.stop() }
        let socks = try await LocalServer.socks5(forwardingTo: echo.port)
        defer { socks.stop() }
        let socksPort = Int(socks.port)
        let relay = try await ClaudeSOCKSRelay.start(route: { _ in .socks(host: "127.0.0.1", port: socksPort) })
        defer { relay.stop() }

        let client = try await TestClient.connect(port: relay.port)
        defer { client.cancel() }
        let status = try await client.connect(target: "api.anthropic.com:443", credential: relay.token)
        #expect(status == "200")
        try await client.send(Data("ping".utf8))
        #expect(try await client.receive(4) == Data("ping".utf8))
        // The proxy got the name, not a locally resolved address.
        #expect(socks.seen == ["api.anthropic.com:443"])
    }

    @Test
    func onlyTheProbeWithItsCredentialMayConnect() async throws {
        let relay = try await ClaudeSOCKSRelay.start(route: { _ in .unresolved })
        defer { relay.stop() }
        for credential in [nil, "wrong"] as [String?] {
            let client = try await TestClient.connect(port: relay.port)
            defer { client.cancel() }
            #expect(try await client.connect(target: "api.anthropic.com:443", credential: credential) == "407")
        }
    }

    @Test
    func onlyConnectToAnthropicsOwnHostsOnPort443() async throws {
        let relay = try await ClaudeSOCKSRelay.start(route: { _ in .unresolved })
        defer { relay.stop() }
        for target in ["example.com:443", "api.anthropic.com:80", "anthropic.com.evil.test:443"] {
            let client = try await TestClient.connect(port: relay.port)
            defer { client.cancel() }
            #expect(try await client.connect(target: target, credential: relay.token) == "403", "\(target)")
        }
        let client = try await TestClient.connect(port: relay.port)
        defer { client.cancel() }
        #expect(try await client.request("GET http://api.anthropic.com/ HTTP/1.1\r\nHost: api.anthropic.com\r\n\r\n") == "405")
        #expect(ClaudeSOCKSRelay.isAllowed(host: "platform.claude.com", port: 443))
        #expect(ClaudeSOCKSRelay.isAllowed(host: "claude.ai", port: 443))
        #expect(!ClaudeSOCKSRelay.isAllowed(host: "notclaude.ai", port: 443))
    }

    /// A route that cannot be resolved right now is refused, never sent direct.
    @Test
    func anUnresolvedRouteIsRefused() async throws {
        let relay = try await ClaudeSOCKSRelay.start(route: { _ in .unresolved })
        defer { relay.stop() }
        let client = try await TestClient.connect(port: relay.port)
        defer { client.cancel() }
        #expect(try await client.connect(target: "api.anthropic.com:443", credential: relay.token) == "502")
    }

    @Test
    func listensOnLoopbackAndStopsWithTheProbe() async throws {
        let relay = try await ClaudeSOCKSRelay.start(route: { _ in .unresolved })
        #expect(relay.proxyURL == "http://vibe-usage:\(relay.token)@127.0.0.1:\(relay.port)")
        #expect(relay.token.count == 48)
        relay.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await LoginLaunch.accepts("127.0.0.1", Int(relay.port)) == false)
    }

    // MARK: - What the probe's Claude Code gets

    @Test
    func aSOCKSOnlySystemProxyGoesThroughTheRelay() async throws {
        let launch = await SystemProxy.claudeLaunch(
            base: ["PATH": "/usr/bin", "no_proxy": "corp.example"],
            routes: { hosts in hosts.map { (host: $0, route: .socks(host: "127.0.0.1", port: 7891)) } },
            startRelay: { route in try await ClaudeSOCKSRelay.start(route: route) }
        )
        let relay = try #require(launch.relay)
        defer { relay.stop() }
        #expect(launch.environment["HTTPS_PROXY"] == relay.proxyURL)
        #expect(launch.environment["HTTP_PROXY"] == relay.proxyURL)
        #expect(launch.environment["ALL_PROXY"] == nil)
        let noProxy = launch.environment["no_proxy"] ?? ""
        #expect(noProxy.contains("corp.example") && noProxy.contains("127.0.0.1"))
    }

    /// The relay keeps the routes resolved at launch: a proxy client that
    /// restarts mid-probe (no system proxy for a moment) cannot make it
    /// connect directly. A host the PAC sent direct stays direct.
    @Test
    func theRelayKeepsTheLaunchRoutes() async throws {
        let captured = RouteBox()
        let launch = await SystemProxy.claudeLaunch(
            base: ["PATH": "/usr/bin"],
            routes: { hosts in hosts.map { host in
                (host: host, route: host == "claude.ai" ? .direct : .socks(host: "127.0.0.1", port: 7891))
            } },
            startRelay: { route in
                captured.route = route
                return try await ClaudeSOCKSRelay.start(route: route)
            }
        )
        defer { launch.relay?.stop() }
        let route = try #require(captured.route)
        #expect(await route(URL(string: "https://api.anthropic.com:443/")!) == .socks(host: "127.0.0.1", port: 7891))
        #expect(await route(URL(string: "https://statsig.anthropic.com:443/")!) == .socks(host: "127.0.0.1", port: 7891))
        #expect(await route(URL(string: "https://claude.ai:443/")!) == .direct)
    }

    @Test
    func aRelayThatCannotStartFailsClosed() async {
        struct Refused: Error {}
        let launch = await SystemProxy.claudeLaunch(
            base: ["PATH": "/usr/bin"],
            routes: { hosts in hosts.map { (host: $0, route: .socks(host: "127.0.0.1", port: 7891)) } },
            startRelay: { _ in throw Refused() }
        )
        #expect(launch.relay == nil)
        #expect(launch.environment["HTTPS_PROXY"] == SystemProxy.failClosedURL)
    }

    @Test
    func anHTTPProxyOrTheUsersOwnNeedsNoRelay() async {
        let http = await SystemProxy.claudeLaunch(
            base: ["PATH": "/usr/bin"],
            routes: { hosts in hosts.map { (host: $0, route: .http(host: "127.0.0.1", port: 7890)) } },
            startRelay: { _ in Issue.record("no relay expected"); throw CancellationError() }
        )
        #expect(http.relay == nil)
        #expect(http.environment["HTTPS_PROXY"] == "http://127.0.0.1:7890")
        let own = await SystemProxy.claudeLaunch(
            base: ["HTTPS_PROXY": "http://10.0.0.2:3128"],
            routes: { _ in Issue.record("system routes not read"); return [] },
            startRelay: { _ in Issue.record("no relay expected"); throw CancellationError() }
        )
        #expect(own.relay == nil)
        #expect(own.environment["HTTPS_PROXY"] == "http://10.0.0.2:3128")
    }
}

// MARK: - Stand-ins

private final class LocalServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var recorded: [String] = []
    private var connections: [NWConnection] = []
    let port: UInt16

    var seen: [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    func stop() {
        listener.cancel()
        lock.lock()
        connections.forEach { $0.cancel() }
        lock.unlock()
    }

    fileprivate func keep(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
    }

    fileprivate func record(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    private static func listen(_ handle: @escaping @Sendable (LocalServer, NWConnection) -> Void) async throws -> LocalServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let box = ServerBox()
        listener.newConnectionHandler = { connection in
            guard let server = box.server else { connection.cancel(); return }
            server.keep(connection)
            connection.start(queue: .global())
            handle(server, connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let fired = Fired()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if let port = listener.port?.rawValue, fired.first() { continuation.resume(returning: port) }
                case let .failed(error): if fired.first() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
        let server = LocalServer(listener: listener, port: port)
        box.server = server
        return server
    }

    static func echo() async throws -> LocalServer {
        try await listen { _, connection in echoLoop(connection) }
    }

    private static func echoLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { _ in echoLoop(connection) })
            } else if complete || error != nil {
                connection.cancel()
            } else {
                echoLoop(connection)
            }
        }
    }

    /// SOCKS5 without authentication that records `name:port` and forwards
    /// to 127.0.0.1:`target`.
    static func socks5(forwardingTo target: UInt16) async throws -> LocalServer {
        try await listen { server, client in
            client.receive(minimumIncompleteLength: 3, maximumLength: 3) { _, _, _, _ in
                client.send(content: Data([5, 0]), completion: .contentProcessed { _ in
                    client.receive(minimumIncompleteLength: 5, maximumLength: 5) { head, _, _, _ in
                        guard let head, head.count == 5, head[3] == 3 else { client.cancel(); return }
                        let length = Int(head[4])
                        client.receive(minimumIncompleteLength: length + 2, maximumLength: length + 2) { rest, _, _, _ in
                            guard let rest, rest.count == length + 2 else { client.cancel(); return }
                            let name = String(decoding: rest.prefix(length), as: UTF8.self)
                            let port = Int(rest[length]) << 8 | Int(rest[length + 1])
                            server.record("\(name):\(port)")
                            let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!, using: .tcp)
                            server.keep(upstream)
                            upstream.stateUpdateHandler = { state in
                                guard case .ready = state else { return }
                                client.send(content: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in
                                    pipe(client, upstream)
                                    pipe(upstream, client)
                                })
                            }
                            upstream.start(queue: .global())
                        }
                    }
                })
            }
        }
    }

    private static func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in pipe(from, to) })
            } else if complete || error != nil {
                to.cancel()
            } else {
                pipe(from, to)
            }
        }
    }
}

private final class ServerBox: @unchecked Sendable { var server: LocalServer? }

private final class RouteBox: @unchecked Sendable { var route: (@Sendable (URL) async -> SystemProxy.Route)? }

private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

private final class TestClient: @unchecked Sendable {
    private let connection: NWConnection

    private init(_ connection: NWConnection) { self.connection = connection }

    static func connect(port: UInt16) async throws -> TestClient {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let fired = Fired()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if fired.first() { continuation.resume() }
                case let .failed(error), let .waiting(error): if fired.first() { continuation.resume(throwing: error) }
                default: break
                }
            }
            connection.start(queue: .global())
        }
        return TestClient(connection)
    }

    func cancel() { connection.cancel() }

    /// Sends a `CONNECT` and returns the status code of the answer.
    func connect(target: String, credential: String?) async throws -> String {
        var request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
        if let credential {
            request += "Proxy-Authorization: Basic \(Data("vibe-usage:\(credential)".utf8).base64EncodedString())\r\n"
        }
        return try await self.request(request + "\r\n")
    }

    func request(_ text: String) async throws -> String {
        try await send(Data(text.utf8))
        var buffer = Data()
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let chunk = try await receive(1, upTo: 1024)
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        let line = String(decoding: buffer, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        return line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive(_ count: Int, upTo maximum: Int? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: maximum ?? count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }
}
