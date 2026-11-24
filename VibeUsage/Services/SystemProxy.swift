import CFNetwork
import Foundation

/// The user's macOS proxy settings, resolved for one URL at a time, and handed
/// to everything the app starts or sends (network-privacy principle, rule 1:
/// follow the user's system proxy, PAC included, in our processes too).
///
/// Before this, only the app's own `URLSession.shared` requests followed the
/// system proxy. The CLI (Node) and Claude Code read proxy environment
/// variables, never system settings, so with the common "system proxy" mode of
/// a proxy client they connected directly. Now:
///
/// - The system answers which proxy a URL uses (`CFNetworkCopyProxiesForURL`,
///   which applies the bypass list). A PAC answer is evaluated by the system
///   too (`CFNetworkExecuteProxyAutoConfigurationURL` / `…Script`, 3 s cap);
///   the app never runs PAC JavaScript itself.
/// - The first entry is the route. `PROXY a; DIRECT` therefore pins `a` and
///   never falls back to direct; a first `DIRECT` is the user's own rule.
/// - The CLI gets `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`, plus
///   `NODE_USE_ENV_PROXY=1` for an HTTP proxy. A SOCKS-only proxy reaches it
///   as `socks5://` without the switch: the CLI then refuses requests that
///   carry a vendor account instead of letting Node connect directly.
///   Claude Code gets the HTTP variables only; it does not support SOCKS
///   (with a SOCKS-only proxy the probe behaves as before).
/// - Codex and OpenCode Go requests pin the route on their own session, so a
///   proxy that is down makes them fail instead of connecting directly.
///
/// Settings are read again for every call; nothing is cached across calls.
/// A PAC that cannot be evaluated is `.unresolved` and fails closed: requests
/// and children are pointed at a closed local port, never sent direct
/// (pausing with an explanation is separate work).
enum SystemProxy {

    enum Route: Equatable, Sendable {
        case direct
        /// An HTTP proxy (CONNECT for https). Also what the system's
        /// "Secure Web Proxy (HTTPS)" setting means.
        case http(host: String, port: Int)
        case socks(host: String, port: Int)
        /// A PAC that could not be fetched or evaluated in time.
        case unresolved
    }

    static let pacTimeout: TimeInterval = 3
    /// One resolution batch (all the hosts a child reaches) gets at most this
    /// long for PAC answers; what is left after it is unresolved.
    static let batchPACBudget: TimeInterval = 6

    /// Where a request goes when its route cannot be resolved (a PAC that is
    /// set but cannot be fetched or evaluated, typically while the proxy
    /// client is restarting): a closed local port, so the request fails
    /// instead of going direct. Never a real proxy.
    static let failClosedHost = "127.0.0.1"
    static let failClosedPort = 1
    static var failClosedURL: String { "http://\(failClosedHost):\(failClosedPort)" }

    // MARK: - Resolution

    static func currentSettings() -> [String: Any]? {
        CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
    }

    /// The route the system would take for `url` under `settings`.
    static func route(for url: URL, settings: [String: Any]?, evaluatingPAC: Bool = true) -> Route {
        guard let settings else { return .unresolved }
        let list = CFNetworkCopyProxiesForURL(url as CFURL, settings as CFDictionary)
            .takeRetainedValue() as? [[String: Any]] ?? []
        return route(from: list, for: url, evaluatingPAC: evaluatingPAC)
    }

    static func route(from list: [[String: Any]], for url: URL, evaluatingPAC: Bool) -> Route {
        guard let first = list.first,
              let type = first[kCFProxyTypeKey as String] as? String
        else { return .unresolved }
        if type == kCFProxyTypeNone as String {
            return .direct
        }
        if type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String {
            guard let endpoint = endpoint(first) else { return .unresolved }
            return .http(host: endpoint.host, port: endpoint.port)
        }
        if type == kCFProxyTypeSOCKS as String {
            guard let endpoint = endpoint(first) else { return .unresolved }
            return .socks(host: endpoint.host, port: endpoint.port)
        }
        if type == kCFProxyTypeAutoConfigurationURL as String
            || type == kCFProxyTypeAutoConfigurationJavaScript as String {
            guard evaluatingPAC, let results = evaluatePAC(first, for: url) else { return .unresolved }
            return route(from: results, for: url, evaluatingPAC: false)
        }
        return .unresolved
    }

    private static func endpoint(_ entry: [String: Any]) -> (host: String, port: Int)? {
        guard let host = entry[kCFProxyHostNameKey as String] as? String, !host.isEmpty,
              let port = (entry[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue, port > 0
        else { return nil }
        return (host, port)
    }

    private final class PACBox: @unchecked Sendable {
        var proxies: [[String: Any]]?
        var done = false
    }

    /// Runs the system's PAC evaluation on the calling thread's run loop, in a
    /// private mode, for at most `pacTimeout`. Call off the main thread.
    private static func evaluatePAC(_ entry: [String: Any], for url: URL) -> [[String: Any]]? {
        let box = PACBox()
        var context = CFStreamClientContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: CFProxyAutoConfigurationResultCallback = { client, proxyList, error in
            let box = Unmanaged<PACBox>.fromOpaque(client).takeUnretainedValue()
            if error == nil { box.proxies = proxyList as? [[String: Any]] }
            box.done = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        let source: CFRunLoopSource
        if let script = entry[kCFProxyAutoConfigurationJavaScriptKey as String] as? String {
            source = CFNetworkExecuteProxyAutoConfigurationScript(
                script as CFString, url as CFURL, callback, &context
            )
        } else if let pacURL = entry[kCFProxyAutoConfigurationURLKey as String] as? URL {
            source = CFNetworkExecuteProxyAutoConfigurationURL(
                pacURL as CFURL, url as CFURL, callback, &context
            )
        } else {
            return nil
        }
        let mode = CFRunLoopMode("ai.vibecafe.vibe-usage.pac" as CFString)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, mode)
        let deadline = Date().addingTimeInterval(pacTimeout)
        while !box.done, deadline.timeIntervalSinceNow > 0 {
            _ = CFRunLoopRunInMode(mode, deadline.timeIntervalSinceNow, true)
        }
        CFRunLoopRemoveSource(runLoop, source, mode)
        CFRunLoopSourceInvalidate(source)
        return box.done ? box.proxies : nil
    }

    // MARK: - Environment for the processes the app starts

    /// Hosts the CLI reaches. A PAC can answer differently per host; one
    /// `HTTPS_PROXY` cannot, so hosts the PAC sends direct join `NO_PROXY`.
    static let cliHosts = [
        "vibefriends.com", "registry.npmjs.org",
        "api.kimi.com", "auth.kimi.com", "open.bigmodel.cn", "api.z.ai",
        "opencode.ai", "cursor.com", "cli-chat-proxy.grok.com",
        "daily-cloudcode-pa.googleapis.com", "generativelanguage.googleapis.com",
        // The CLI's egress check asks one of these for Google, and only when
        // its own route is direct too, so a PAC answer for them must reach it.
        "chatgpt.com", "api.anthropic.com",
    ]

    /// Hosts the Claude Code probe reaches (Claude Code's network docs).
    static let claudeHosts = ["api.anthropic.com", "platform.claude.com", "claude.ai"]

    static let proxyVariableNames = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]
    static let allProxyNames = ["ALL_PROXY", "all_proxy"]
    static let loopback = ["localhost", "127.0.0.1", "::1"]

    /// Variables to add to a child's environment so it follows the system
    /// proxy. Empty when there is nothing to follow (no proxy, all direct, or
    /// nothing resolvable). A proxy the user already put in the environment
    /// is kept as it is.
    static func proxyVariables(
        routes: [(host: String, route: Route)],
        base: [String: String],
        allowSOCKS: Bool,
        nodeSwitch: Bool
    ) -> [String: String] {
        var out: [String: String] = [:]
        if hasOwnProxy(base) {
            // The user's own proxy wins over the system's. Pick the proxy each
            // scheme really uses (the CLI's order: the scheme's own variable,
            // then ALL_PROXY, and for https an HTTP_PROXY last) and write those
            // two out explicitly, so Node's startup switch and older CLIs see
            // what the CLI itself would choose; a value without a scheme is
            // written as `http://…` (Node with the switch refuses to start on
            // it). A SOCKS choice gets no switch: the CLI refuses vendor
            // requests it cannot route.
            let https = firstValue(base, ["https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY", "http_proxy", "HTTP_PROXY"])
            let http = firstValue(base, ["http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"])
            if ![https, http].contains(where: { $0.map(isSOCKS) ?? false }) {
                // Lowercase spellings too: Node prefers them when both exist.
                if let https {
                    out["HTTPS_PROXY"] = withScheme(https)
                    if base["https_proxy"] != nil { out["https_proxy"] = withScheme(https) }
                }
                if let http {
                    out["HTTP_PROXY"] = withScheme(http)
                    if base["http_proxy"] != nil { out["http_proxy"] = withScheme(http) }
                }
                if nodeSwitch { out["NODE_USE_ENV_PROXY"] = "1" }
            }
            setNoProxy(&out, noProxy(base: base, adding: []), base: base)
            return out
        }

        let proxyURL: String
        var http = false
        if let found = mostCommon(routes.compactMap { item -> String? in
            if case let .http(host, port) = item.route { return "http://\(hostPart(host)):\(port)" }
            return nil
        }) {
            proxyURL = found
            http = true
        } else if allowSOCKS, let socks = mostCommon(routes.compactMap { item -> String? in
            // `socks5://`, not `socks5h://`: Node 24 with NODE_USE_ENV_PROXY
            // refuses to start on `socks5h` (measured 2026-11-24).
            if case let .socks(host, port) = item.route { return "socks5://\(hostPart(host)):\(port)" }
            return nil
        }) {
            proxyURL = socks
            out["ALL_PROXY"] = socks
        } else if routes.contains(where: { $0.route == .unresolved }) {
            // A PAC that cannot be evaluated right now: a closed local port,
            // so the child fails instead of connecting directly.
            proxyURL = failClosedURL
            http = true
        } else {
            return [:]
        }
        out["HTTPS_PROXY"] = proxyURL
        out["HTTP_PROXY"] = proxyURL
        let direct = routes.filter { $0.route == .direct }.map(\.host)
        setNoProxy(&out, noProxy(base: base, adding: direct), base: base)
        // Node's switch only for an HTTP proxy: Node's https cannot follow
        // SOCKS, and the CLI refuses vendor requests it cannot route rather
        // than letting them go direct.
        if nodeSwitch, http { out["NODE_USE_ENV_PROXY"] = "1" }
        return out
    }

    /// The bypass list Node would use (lowercase `no_proxy` first; an empty
    /// value counts as unset) plus loopback (`[::1]` too, as Node's fetch
    /// matches the bracketed host) and `hosts`. Nil when it says `*`, which
    /// must stay exactly `*`.
    private static func noProxy(base: [String: String], adding hosts: [String]) -> String? {
        var entries = (firstValue(base, ["no_proxy", "NO_PROXY"]) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        if entries.contains("*") { return nil }
        for host in loopback + ["[::1]"] + hosts
            where !entries.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) {
            entries.append(host)
        }
        return entries.joined(separator: ",")
    }

    /// Node prefers a lowercase `no_proxy` when both exist, so it is kept in
    /// step whenever the user had one.
    private static func setNoProxy(_ out: inout [String: String], _ value: String?, base: [String: String]) {
        guard let value else { return }
        out["NO_PROXY"] = value
        if base["no_proxy"] != nil { out["no_proxy"] = value }
    }

    private static func firstValue(_ base: [String: String], _ names: [String]) -> String? {
        names.lazy.compactMap { base[$0]?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    private static func withScheme(_ value: String) -> String {
        value.contains("://") ? value : "http://\(value)"
    }

    private static func isSOCKS(_ value: String) -> Bool {
        value.lowercased().hasPrefix("socks")
    }

    private static func hostPart(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// The most frequent value, the earliest one on a tie.
    private static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        var best: String?
        var bestCount = 0
        for value in values where counts[value]! > bestCount {
            best = value
            bestCount = counts[value]!
        }
        return best
    }

    /// The system routes for `urls`, read now. Runs off the main thread and
    /// off the Swift concurrency pool (PAC evaluation waits on a run loop).
    static func routes(for urls: [URL]) async -> [Route] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let settings = currentSettings()
                // Each URL keeps its own answer; once the batch budget is
                // spent, the rest are unresolved (and fail closed).
                let deadline = Date().addingTimeInterval(batchPACBudget)
                let routes = urls.map { url -> Route in
                    route(for: url, settings: settings, evaluatingPAC: Date() < deadline)
                }
                continuation.resume(returning: routes)
            }
        }
    }

    static func routes(forHosts hosts: [String]) async -> [(host: String, route: Route)] {
        let urls = hosts.map { URL(string: "https://\($0)/")! }
        return Array(zip(hosts, await routes(for: urls))).map { (host: $0.0, route: $0.1) }
    }

    /// For the CLI (Node): HTTP or SOCKS. The CLI refuses vendor requests it
    /// cannot route (a SOCKS proxy under Node), instead of going direct.
    static func cliEnvironment(base: [String: String]) async -> [String: String] {
        var env = base
        var routes: [(host: String, route: Route)] = []
        if !hasOwnProxy(base) {
            // The CLI's fixed hosts, plus the user's own registry and server
            // resolved by their real URL (scheme and port matter to a PAC).
            let urls = cliHosts.map { URL(string: "https://\($0)/")! } + configuredCLIURLs()
            routes = zip(urls, await self.routes(for: urls)).map { (host: $0.0.host ?? "", route: $0.1) }
        }
        let variables = proxyVariables(routes: routes, base: base, allowSOCKS: true, nodeSwitch: true)
        env.merge(variables) { _, proxy in proxy }
        return env
    }

    /// Claude Code's environment, plus the relay it needs when the system
    /// routes Anthropic's hosts through SOCKS only (`ClaudeSOCKSRelay`; the
    /// caller stops it when the probe ends). Claude Code speaks only HTTP
    /// proxies: without the relay it would connect directly. A relay that
    /// cannot start points Claude Code at the closed port instead.
    static func claudeLaunch(
        base: [String: String],
        routes resolve: ([String]) async -> [(host: String, route: Route)] = { await routes(forHosts: $0) },
        startRelay: (@escaping @Sendable (URL) async -> Route) async throws -> ClaudeSOCKSRelay = {
            try await ClaudeSOCKSRelay.start(route: $0)
        }
    ) async -> (environment: [String: String], relay: ClaudeSOCKSRelay?) {
        var env = base
        let routes = hasOwnProxy(base) ? [] : await resolve(claudeHosts)
        let socksOnly = routes.contains { if case .socks = $0.route { return true }; return false }
            && !routes.contains { if case .http = $0.route { return true }; return false }
        if socksOnly {
            // The relay keeps the routes resolved here for the whole probe:
            // a proxy client that restarts mid-probe briefly leaves no system
            // proxy, which must not turn into a direct connection. A host the
            // PAC sent direct stays direct (the user's rule); any other
            // Anthropic host takes the SOCKS proxy.
            let fixed = Dictionary(routes.map { ($0.host.lowercased(), $0.route) }, uniquingKeysWith: { first, _ in first })
            let socks = routes.first { if case .socks = $0.route { return true }; return false }?.route ?? .unresolved
            let relayRoute: @Sendable (URL) async -> Route = { url in
                fixed[(url.host ?? "").lowercased()] ?? socks
            }
            let relay = try? await startRelay(relayRoute)
            let proxyURL = relay?.proxyURL ?? failClosedURL
            env["HTTPS_PROXY"] = proxyURL
            env["HTTP_PROXY"] = proxyURL
            for name in ["https_proxy", "http_proxy"] where base[name] != nil { env[name] = proxyURL }
            let direct = routes.filter { $0.route == .direct }.map(\.host)
            setNoProxy(&env, noProxy(base: base, adding: direct), base: base)
            return (env, relay)
        }
        let variables = proxyVariables(routes: routes, base: base, allowSOCKS: false, nodeSwitch: false)
        env.merge(variables) { _, proxy in proxy }
        return (env, nil)
    }

    static func hasOwnProxy(_ base: [String: String]) -> Bool {
        (proxyVariableNames + allProxyNames).contains {
            !(base[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// The URLs the CLI reaches that the user chose: the npm registry the
    /// launcher asks and the configured Vibe Usage server. A PAC may send a
    /// mirror or an intranet server direct.
    static func configuredCLIURLs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        apiURL: String? = ConfigManager.load()?.apiUrl
    ) -> [URL] {
        var urls: [URL] = []
        let npmrc = try? String(contentsOf: home.appendingPathComponent(".npmrc"), encoding: .utf8)
        if let registry = launcherRegistry(npmrc: npmrc) { urls.append(registry) }
        if let apiURL, let url = URL(string: apiURL), url.host != nil { urls.append(url) }
        return urls.filter { !cliHosts.contains($0.host ?? "") }
    }

    /// The registry `cli-bootstrap.mjs` asks, read the same way: the last
    /// `@vibe-cafe:registry`, else the last `registry`; quotes stripped; https
    /// only; a registry the file holds credentials for (`//host/…:_authToken=`)
    /// is skipped, as the launcher then uses the official one.
    static func launcherRegistry(npmrc: String?) -> URL? {
        guard let npmrc else { return nil }
        var scoped: String?
        var plain: String?
        var credentialHosts: Set<String> = []
        for line in npmrc.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            // An unquoted value ends at a `#` or `;` comment, as the launcher reads it.
            var raw = parts[1]
            if !raw.hasPrefix("\""), !raw.hasPrefix("'"), let cut = raw.firstIndex(where: { $0 == "#" || $0 == ";" }) {
                raw = String(raw[..<cut]).trimmingCharacters(in: .whitespaces)
            }
            let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if parts[0] == "@vibe-cafe:registry" { scoped = value }
            else if parts[0] == "registry" { plain = value }
            else if parts[0].hasPrefix("//"), parts[0].contains(":") {
                let host = parts[0].dropFirst(2).split(separator: "/").first.map(String.init)?
                    .split(separator: ":").first.map(String.init)
                if let host { credentialHosts.insert(host.lowercased()) }
            }
        }
        guard let value = scoped ?? plain, let url = URL(string: value), url.scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host, !credentialHosts.contains(host.lowercased())
        else { return nil }
        return url
    }

    // MARK: - Sessions for the app's own vendor requests

    /// A `URLSession` configuration whose proxy is the given route, so a dead
    /// proxy fails the request instead of letting it go direct. An
    /// unresolvable PAC fails closed the same way.
    static func configuration(for route: Route) -> URLSessionConfiguration {
        let disabled: [AnyHashable: Any] = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0,
        ]
        var dictionary = disabled
        switch route {
        case .unresolved:
            // Fail closed: a closed local port, never direct.
            dictionary["HTTPEnable"] = 1
            dictionary["HTTPProxy"] = failClosedHost
            dictionary["HTTPPort"] = failClosedPort
            dictionary["HTTPSEnable"] = 1
            dictionary["HTTPSProxy"] = failClosedHost
            dictionary["HTTPSPort"] = failClosedPort
        case .direct:
            break
        case let .http(host, port):
            dictionary["HTTPEnable"] = 1
            dictionary["HTTPProxy"] = host
            dictionary["HTTPPort"] = port
            dictionary["HTTPSEnable"] = 1
            dictionary["HTTPSProxy"] = host
            dictionary["HTTPSPort"] = port
        case let .socks(host, port):
            dictionary["SOCKSEnable"] = 1
            dictionary["SOCKSProxy"] = host
            dictionary["SOCKSPort"] = port
        }
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = dictionary
        return configuration
    }

    /// One request through the system route for its URL, read now.
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { return try await URLSession.shared.data(for: request) }
        let route = await routes(for: [url]).first ?? .unresolved
        let session = URLSession(configuration: configuration(for: route))
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}
