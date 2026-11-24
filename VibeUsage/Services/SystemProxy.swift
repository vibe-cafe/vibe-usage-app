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
/// A PAC that cannot be evaluated is `.unresolved`: callers then keep their
/// previous behavior (this is the plain "follow the proxy" step; pausing
/// requests that cannot be routed is separate work).
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
        let own = (proxyVariableNames + allProxyNames).compactMap { name -> (String, String)? in
            guard let value = base[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return (name, value)
        }
        if !own.isEmpty {
            // The user's own proxy wins over the system's (the CLI and Claude
            // Code read these variables), as on Windows. A value without a
            // scheme is written out as `http://…` for the child: Node with
            // NODE_USE_ENV_PROXY refuses to start on it (measured).
            var httpValue = false
            for (name, value) in own {
                if isSOCKS(value) { continue }
                if !value.contains("://") { out[name] = "http://\(value)" }
                if proxyVariableNames.contains(name) { httpValue = true }
            }
            setNoProxy(&out, noProxy(base: base, adding: []), base: base)
            if nodeSwitch, httpValue, !own.contains(where: { isSOCKS($0.1) }) { out["NODE_USE_ENV_PROXY"] = "1" }
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

    /// Both spellings merged (Node prefers lowercase, other programs
    /// uppercase) plus loopback and `hosts`. Nil when either already says
    /// `*`, which must stay exactly `*` to bypass everything.
    private static func noProxy(base: [String: String], adding hosts: [String]) -> String? {
        var entries: [String] = []
        for name in ["no_proxy", "NO_PROXY"] {
            for entry in (base[name] ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                where !entries.contains(entry) {
                entries.append(entry)
            }
        }
        if entries.contains("*") { return nil }
        for host in loopback + hosts where !entries.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) {
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
                // Once a PAC cannot be evaluated, the rest of the batch is
                // unresolved too instead of waiting `pacTimeout` per URL.
                var pacFailed = false
                let routes = urls.map { url -> Route in
                    let route = route(for: url, settings: settings, evaluatingPAC: !pacFailed)
                    if route == .unresolved { pacFailed = true }
                    return route
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
        let hosts = hasOwnProxy(base) ? [] : cliHosts + configuredCLIHosts(base: base)
        let variables = proxyVariables(
            routes: await routes(forHosts: hosts), base: base, allowSOCKS: true, nodeSwitch: true
        )
        env.merge(variables) { _, proxy in proxy }
        return env
    }

    /// For Claude Code: HTTP only (it does not support SOCKS).
    static func claudeEnvironment(base: [String: String]) async -> [String: String] {
        var env = base
        let hosts = hasOwnProxy(base) ? [] : claudeHosts
        let variables = proxyVariables(
            routes: await routes(forHosts: hosts), base: base, allowSOCKS: false, nodeSwitch: false
        )
        env.merge(variables) { _, proxy in proxy }
        return env
    }

    static func hasOwnProxy(_ base: [String: String]) -> Bool {
        (proxyVariableNames + allProxyNames).contains {
            !(base[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// The hosts the CLI reaches that the user chose: the npm registry the
    /// launcher asks (`~/.npmrc`'s `@vibe-cafe:registry`, else `registry`, as
    /// `cli-bootstrap.mjs` reads it) and the configured Vibe Usage server. A
    /// PAC may send a mirror or an intranet server direct.
    static func configuredCLIHosts(
        base: [String: String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        apiURL: String? = ConfigManager.load()?.apiUrl
    ) -> [String] {
        var hosts: [String] = []
        if let text = try? String(contentsOf: home.appendingPathComponent(".npmrc"), encoding: .utf8) {
            var scoped: String?
            var plain: String?
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == "@vibe-cafe:registry" { scoped = parts[1] }
                if parts[0] == "registry" { plain = parts[1] }
            }
            if let value = scoped ?? plain, let host = URL(string: value)?.host { hosts.append(host) }
        }
        if let apiURL, let host = URL(string: apiURL)?.host { hosts.append(host) }
        return hosts.filter { !cliHosts.contains($0) }
    }

    // MARK: - Sessions for the app's own vendor requests

    /// A `URLSession` configuration whose proxy is the given route, so a dead
    /// proxy fails the request instead of letting it go direct. Nil for
    /// `.unresolved`: the caller keeps the system's own handling.
    static func configuration(for route: Route) -> URLSessionConfiguration? {
        let disabled: [AnyHashable: Any] = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0,
        ]
        var dictionary = disabled
        switch route {
        case .unresolved:
            return nil
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
        guard let configuration = configuration(for: route) else {
            return try await URLSession.shared.data(for: request)
        }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}
