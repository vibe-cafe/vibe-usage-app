import Foundation
import Network
import Testing
@testable import VibeUsage

/// `SystemProxy` hands the user's macOS proxy settings to every request and
/// child process. The system resolver is driven with settings dictionaries of
/// the same shape `CFNetworkCopySystemProxySettings` returns, so these tests
/// never read or change the machine's real settings, and the stand-in proxy
/// below listens on 127.0.0.1 and connects nowhere.
struct SystemProxyTests {

    private let chatgpt = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let bigmodel = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!

    @Test
    func noProxySettingsMeanDirect() {
        #expect(SystemProxy.route(for: chatgpt, settings: [:]) == .direct)
        #expect(SystemProxy.route(for: chatgpt, settings: ["HTTPSEnable": 0]) == .direct)
        #expect(SystemProxy.route(for: chatgpt, settings: nil) == .unresolved)
    }

    /// The common "system proxy" mode of a proxy client.
    @Test
    func httpsProxyAndBypassList() {
        let settings: [String: Any] = [
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
            "ExceptionsList": ["open.bigmodel.cn"],
        ]
        #expect(SystemProxy.route(for: chatgpt, settings: settings) == .http(host: "127.0.0.1", port: 7890))
        #expect(SystemProxy.route(for: bigmodel, settings: settings) == .direct)
    }

    @Test
    func socksOnlyProxy() {
        let settings: [String: Any] = ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7891]
        #expect(SystemProxy.route(for: chatgpt, settings: settings) == .socks(host: "127.0.0.1", port: 7891))
    }

    /// PAC is evaluated by the system. The first answer wins: a `DIRECT`
    /// fallback after a proxy is never taken, a first `DIRECT` is the user's
    /// own rule.
    @Test
    func pacIsEvaluatedByTheSystemAndTheFirstAnswerWins() {
        let script = """
        function FindProxyForURL(url, host) {
          if (dnsDomainIs(host, "open.bigmodel.cn")) return "DIRECT";
          return "PROXY 127.0.0.1:7890; DIRECT";
        }
        """
        let settings: [String: Any] = ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigJavaScript": script]
        #expect(SystemProxy.route(for: chatgpt, settings: settings) == .http(host: "127.0.0.1", port: 7890))
        #expect(SystemProxy.route(for: bigmodel, settings: settings) == .direct)

        let socks: [String: Any] = [
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigJavaScript": #"function FindProxyForURL(u, h) { return "SOCKS 127.0.0.1:7891"; }"#,
        ]
        #expect(SystemProxy.route(for: chatgpt, settings: socks) == .socks(host: "127.0.0.1", port: 7891))

        // Proxy clients often write `SOCKS5 …; SOCKS …; DIRECT`. The system
        // resolver does not know `SOCKS5`; whatever it makes of the line, the
        // trailing DIRECT must not become the route.
        let mixed: [String: Any] = [
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigJavaScript": #"function FindProxyForURL(u, h) { return "SOCKS5 127.0.0.1:7891; SOCKS 127.0.0.1:7891; DIRECT"; }"#,
        ]
        #expect(SystemProxy.route(for: chatgpt, settings: mixed) != .direct)
    }

    @Test
    func aPACThatCannotBeEvaluatedIsUnresolved() {
        let broken: [String: Any] = ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigJavaScript": "function ("]
        #expect(SystemProxy.route(for: chatgpt, settings: broken) == .unresolved)
    }

    // MARK: - Environment for child processes

    private func variables(
        _ routes: [(String, SystemProxy.Route)],
        base: [String: String] = [:],
        allowSOCKS: Bool = true,
        nodeSwitch: Bool = true
    ) -> [String: String] {
        SystemProxy.proxyVariables(
            routes: routes.map { (host: $0.0, route: $0.1) }, base: base,
            allowSOCKS: allowSOCKS, nodeSwitch: nodeSwitch
        )
    }

    @Test
    func anHTTPProxyBecomesProxyVariablesWithPACDirectHostsBypassed() {
        let env = variables([
            ("cursor.com", .http(host: "127.0.0.1", port: 7890)),
            ("open.bigmodel.cn", .direct),
            ("api.kimi.com", .direct),
        ], base: ["NO_PROXY": "corp.example"])
        #expect(env == [
            "HTTPS_PROXY": "http://127.0.0.1:7890",
            "HTTP_PROXY": "http://127.0.0.1:7890",
            "NO_PROXY": "corp.example,localhost,127.0.0.1,::1,open.bigmodel.cn,api.kimi.com",
            "NODE_USE_ENV_PROXY": "1",
        ])
    }

    @Test
    func theProxyMostHostsUseIsChosenAndIPv6IsBracketed() {
        let env = variables([
            ("a", .http(host: "::1", port: 1)),
            ("b", .http(host: "10.0.0.2", port: 2)),
            ("c", .http(host: "::1", port: 1)),
        ])
        #expect(env["HTTPS_PROXY"] == "http://[::1]:1")
    }

    /// SOCKS goes to the CLI as `socks5://` without Node's switch (Node 24
    /// with the switch refuses to start on `socks5h://`; the CLI then refuses
    /// vendor requests rather than letting Node connect directly) and never
    /// to Claude Code, which does not support SOCKS.
    @Test
    func socksIsPassedOnlyWhereAllowed() {
        let routes: [(String, SystemProxy.Route)] = [("api.anthropic.com", .socks(host: "127.0.0.1", port: 7891))]
        let cli = variables(routes)
        #expect(cli["HTTPS_PROXY"] == "socks5://127.0.0.1:7891")
        #expect(cli["ALL_PROXY"] == "socks5://127.0.0.1:7891")
        #expect(cli["NODE_USE_ENV_PROXY"] == nil)
        #expect(variables(routes, allowSOCKS: false, nodeSwitch: false).isEmpty)
        // A SOCKS value the user set themselves does not get the switch either.
        #expect(variables([], base: ["ALL_PROXY": "x", "HTTPS_PROXY": "socks5h://h:1"])["NODE_USE_ENV_PROXY"] == nil)
    }

    @Test
    func nothingToFollowAddsNothing() {
        #expect(variables([("a", .direct), ("b", .unresolved)]).isEmpty)
        #expect(variables([]).isEmpty)
    }

    /// A proxy the user already put in the environment is theirs: kept, with
    /// loopback bypassed and Node told to honour it.
    @Test
    func theUsersOwnProxyVariablesAreKept() {
        let env = variables(
            [("a", .http(host: "127.0.0.1", port: 7890))],
            base: ["https_proxy": "http://corp:8080", "no_proxy": "corp.example"]
        )
        #expect(env == [
            "NO_PROXY": "corp.example,localhost,127.0.0.1,::1",
            "no_proxy": "corp.example,localhost,127.0.0.1,::1",
            "NODE_USE_ENV_PROXY": "1",
        ])
    }

    /// A proxy variable without a scheme makes Node (with the switch) refuse
    /// to start, so the child gets it as `http://…`.
    @Test
    func theUsersSchemeLessProxyIsWrittenOutWithAScheme() {
        let env = variables([], base: ["HTTPS_PROXY": "127.0.0.1:7890"])
        #expect(env["HTTPS_PROXY"] == "http://127.0.0.1:7890")
        #expect(env["NODE_USE_ENV_PROXY"] == "1")
    }

    /// An explicit ALL_PROXY is the user's choice: the system proxy is not
    /// written over it (the CLI reads ALL_PROXY when nothing else is set).
    @Test
    func theUsersOwnAllProxyWinsOverTheSystem() {
        let env = variables(
            [("cursor.com", .direct), ("api.kimi.com", .http(host: "127.0.0.1", port: 7890))],
            base: ["ALL_PROXY": "socks5://127.0.0.1:7891"]
        )
        #expect(env["HTTPS_PROXY"] == nil)
        #expect(env["HTTP_PROXY"] == nil)
        #expect(env["NODE_USE_ENV_PROXY"] == nil)
        #expect(env["NO_PROXY"] == "localhost,127.0.0.1,::1")
        #expect(SystemProxy.hasOwnProxy(["all_proxy": "x"]))
        #expect(!SystemProxy.hasOwnProxy(["NO_PROXY": "x"]))
    }

    /// Both bypass spellings are merged, and a `*` stays exactly `*`.
    @Test
    func noProxySpellingsMergeAndStarIsLeftAlone() {
        let route: [(String, SystemProxy.Route)] = [("a", .http(host: "127.0.0.1", port: 7890))]
        let merged = variables(route, base: ["NO_PROXY": "upper.example", "no_proxy": "lower.example"])
        #expect(merged["NO_PROXY"] == "lower.example,upper.example,localhost,127.0.0.1,::1")
        #expect(merged["no_proxy"] == merged["NO_PROXY"])
        let star = variables(route, base: ["NO_PROXY": "*"])
        #expect(star["NO_PROXY"] == nil)
        #expect(star["HTTPS_PROXY"] == "http://127.0.0.1:7890")
    }

    /// A mirror in ~/.npmrc and a custom server are resolved too, so a PAC
    /// that sends them direct puts them in NO_PROXY.
    @Test
    func configuredRegistryAndServerHostsAreResolved() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vu-npmrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("registry=https://registry.npmmirror.com/\n//registry.npmmirror.com/:_authToken=secret\n".utf8)
            .write(to: home.appendingPathComponent(".npmrc"))
        #expect(SystemProxy.configuredCLIHosts(base: [:], home: home, apiURL: "https://usage.corp.example")
            == ["registry.npmmirror.com", "usage.corp.example"])
        try Data("registry=https://a.example/\n@vibe-cafe:registry=https://b.example/\n".utf8)
            .write(to: home.appendingPathComponent(".npmrc"))
        #expect(SystemProxy.configuredCLIHosts(base: [:], home: home, apiURL: "https://vibefriends.com")
            == ["b.example"])
    }

    // MARK: - Pinned sessions, against a stand-in proxy

    @Test
    func directAndUnresolvedSessionConfigurations() throws {
        #expect(SystemProxy.configuration(for: .unresolved) == nil)
        let direct = try #require(SystemProxy.configuration(for: .direct)?.connectionProxyDictionary)
        #expect(direct["HTTPSEnable"] as? Int == 0)
        #expect(direct["SOCKSEnable"] as? Int == 0)
        #expect(direct["ProxyAutoConfigEnable"] as? Int == 0)
    }

    @Test
    func aPinnedHTTPProxyReceivesTheRequest() async throws {
        let proxy = try await StandInProxy.start()
        defer { proxy.stop() }
        let configuration = try #require(SystemProxy.configuration(for: .http(host: "127.0.0.1", port: proxy.port)))
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        _ = try? await session.data(from: URL(string: "https://vibe-usage-proxy-test.invalid/x")!)
        let first = try #require(proxy.firstChunks().first)
        #expect(String(decoding: first, as: UTF8.self).hasPrefix("CONNECT vibe-usage-proxy-test.invalid:443"))
    }

    @Test
    func aPinnedSOCKSProxyReceivesTheRequest() async throws {
        let proxy = try await StandInProxy.start()
        defer { proxy.stop() }
        let configuration = try #require(SystemProxy.configuration(for: .socks(host: "127.0.0.1", port: proxy.port)))
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        _ = try? await session.data(from: URL(string: "https://vibe-usage-proxy-test.invalid/x")!)
        let first = try #require(proxy.firstChunks().first)
        #expect(first.first == 0x05) // SOCKS5 greeting
    }

    // MARK: - Login launch

    @Test
    func loginItemLaunchIsRecognized() {
        func openEvent(loginItem: Bool) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor.appleEvent(
                withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            if loginItem {
                event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
                               forKeyword: AEKeyword(keyAEPropData))
            }
            return event
        }
        #expect(LoginLaunch.isLoginItemLaunch(event: openEvent(loginItem: true), loginItemEnabled: false, systemUptime: 9_999))
        #expect(!LoginLaunch.isLoginItemLaunch(event: openEvent(loginItem: false), loginItemEnabled: false, systemUptime: 10))
        #expect(!LoginLaunch.isLoginItemLaunch(event: nil, loginItemEnabled: true, systemUptime: 9_999))
        // The mark is undocumented for SMAppService: an enabled login item
        // right after the system started counts too.
        #expect(LoginLaunch.isLoginItemLaunch(event: nil, loginItemEnabled: true, systemUptime: 60))
    }
}

/// Listens on 127.0.0.1, records the first bytes of each connection, answers
/// 502 and closes. Never connects anywhere.
final class StandInProxy: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "stand-in-proxy")
    private let lock = NSLock()
    private var chunks: [Data] = []
    private(set) var port: Int = 0

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> StandInProxy {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let proxy = StandInProxy(listener: try NWListener(using: parameters))
        proxy.listener.newConnectionHandler = { [proxy] connection in
            connection.start(queue: proxy.queue)
            proxy.read(connection, buffer: Data())
        }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            proxy.listener.stateUpdateHandler = { [proxy] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: Int(proxy.listener.port?.rawValue ?? 0)) }
                case let .failed(error):
                    if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            proxy.listener.start(queue: proxy.queue)
        }
        proxy.port = port
        return proxy
    }

    /// Reads until a full request line (HTTP) or the SOCKS greeting has
    /// arrived, records it, answers 502 and closes.
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, isComplete, error in
            let buffer = buffer + (data ?? Data())
            let socks = buffer.first == 0x05
            if !socks, !buffer.contains(Data("\r\n".utf8)), !isComplete, error == nil {
                read(connection, buffer: buffer)
                return
            }
            lock.withLock { chunks.append(buffer) }
            let reply = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8)
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func firstChunks() -> [Data] { lock.withLock { chunks } }
    func stop() { listener.cancel() }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
