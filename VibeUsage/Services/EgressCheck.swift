import CryptoKit
import Darwin
import Foundation

/// The egress check before a vendor-account read that goes out direct
/// (network-privacy principle, rule 3, workspace AGENTS.md; maintenance plan
/// 「代理与地区风险-修复方案」§3.4, decided by the maintainer 2026-11-24).
///
/// When the system routes the vendor's host through a proxy (system proxy,
/// PAC, the app's own proxy variables), the request follows it
/// (`SystemProxy`) and nothing here runs. When the route is direct — no proxy,
/// the user's bypass list or a PAC `DIRECT`, or a proxy this Mac cannot see
/// (TUN, a proxy on the router) — the app first asks the vendor's Cloudflare
/// edge on the same direct route which country it sees: an anonymous
/// `GET https://<host>/cdn-cgi/trace` with no cookie, token or account header,
/// of which only the two-letter `loc=` is read. A country the vendor does not
/// serve, or no answer, pauses the read: nothing carrying the account is sent,
/// and the card says why (`LiveFailure.egress…`). The next read checks again.
///
/// The app checks Codex (`chatgpt.com`) and Claude (Anthropic's hosts, all of
/// which have a trace page). Grok and Antigravity are checked by the CLI, which
/// gets the two settings below as environment variables (`cliEnvironment`).
enum EgressCheck {
    /// Regions the paused vendors (OpenAI, Anthropic, xAI, Google) do not
    /// serve and our users may be in.
    static let unsupportedRegions: Set<String> = ["CN", "HK", "MO"]

    static let supportedLifetime: TimeInterval = 600
    static let pausedLifetime: TimeInterval = 60
    static let timeout: TimeInterval = 5
    static let maxBodyBytes = 4096

    // MARK: - Settings (the app's own preferences)

    /// Settings → 订阅配额 → 隐私保护 → 「没检测到代理时」, one of three
    /// (the maintainer's wording, 2026-11-25).
    enum Mode: String, CaseIterable, Identifiable {
        /// 「自动判断（推荐）」, the default: check the egress first.
        case auto
        /// 「暂停读取」: a direct read always pauses, and no check is sent.
        case pause
        /// 「照常读取」: no check; a direct read is sent as before.
        case allow

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: return "自动判断（推荐）"
            case .pause: return "暂停读取"
            case .allow: return "照常读取"
            }
        }
    }

    static let modeKey = "egressMode"
    /// The two switches that came before the menu (development builds only,
    /// never released): read once to pick the matching option, then removed.
    static let legacyEnabledKey = "egressCheckEnabled"
    static let legacyRequireProxyKey = "egressRequireLocalProxy"

    static func mode(_ defaults: UserDefaults = .standard) -> Mode {
        if let raw = defaults.string(forKey: modeKey) { return Mode(rawValue: raw) ?? .auto }
        if defaults.bool(forKey: legacyRequireProxyKey) { return .pause }
        if defaults.object(forKey: legacyEnabledKey) as? Bool == false { return .allow }
        return .auto
    }

    static func setMode(_ mode: Mode, _ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
        defaults.removeObject(forKey: legacyEnabledKey)
        defaults.removeObject(forKey: legacyRequireProxyKey)
    }

    /// Off only for 「照常读取」.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        mode(defaults) != .allow
    }

    /// On only for 「暂停读取」.
    static func requiresProxy(_ defaults: UserDefaults = .standard) -> Bool {
        mode(defaults) == .pause
    }

    /// The same two settings for the CLI, which checks Antigravity itself.
    /// Both are always written out, so a value the user set in their own
    /// environment for the terminal cannot override what Settings shows.
    static func cliEnvironment(_ defaults: UserDefaults = .standard) -> [String: String] {
        [
            "VIBE_USAGE_EGRESS_CHECK": isEnabled(defaults) ? "1" : "0",
            "VIBE_USAGE_REQUIRE_PROXY": requiresProxy(defaults) ? "1" : "0",
        ]
    }

    // MARK: - Decision

    /// A read that was deliberately not sent. Classified `.absent` so the
    /// coordinator handles it as it handles a missing source: a reading
    /// already on screen stays with this reason under it, otherwise the card
    /// shows the reason with no retry button.
    struct Paused: RateLimitFetchError, Equatable {
        enum Reason: Equatable {
            case regionUnsupported(String)
            case unconfirmed
            case proxyNotDetected
        }

        let reason: Reason

        var rateLimitFailure: RateLimitFetchFailure { .absent }

        var liveFailure: ProviderRateLimit.LiveFailure? {
            switch reason {
            case let .regionUnsupported(region): return .egressRegionUnsupported(region)
            case .unconfirmed: return .egressUnconfirmed
            case .proxyNotDetected: return .proxyNotDetected
            }
        }
    }

    /// Throws `Paused` when a read whose route is direct must not go out:
    /// the manual setting, an unsupported country, or no answer. Returns when
    /// it may go ahead (also with the check switched off).
    static func requireDirect(
        traceHost: String,
        defaults: UserDefaults = .standard,
        checker: Checker = .shared
    ) async throws {
        if requiresProxy(defaults) { throw Paused(reason: .proxyNotDetected) }
        guard isEnabled(defaults) else { return }
        guard let region = await checker.region(through: traceHost) else {
            throw Paused(reason: .unconfirmed)
        }
        if unsupportedRegions.contains(region) { throw Paused(reason: .regionUnsupported(region)) }
    }

    /// The hosts Codex's usage URL may name that are OpenAI's own and have a
    /// trace page. A `chatgpt_base_url` pointing elsewhere is a relay the user
    /// chose: OpenAI sees the relay, not this Mac, so there is nothing to check.
    static let openAIHosts: Set<String> = ["chatgpt.com", "chat.openai.com"]

    /// Before each Codex account request (every attempt: the session reads the
    /// route again for each one, and a proxy client that quit between attempts
    /// leaves it direct): checked only when that URL's system route is direct.
    static func checkCodex(
        url: URL,
        route: @escaping @Sendable (URL) async -> SystemProxy.Route = { await SystemProxy.routes(for: [$0]).first ?? .unresolved },
        defaults: UserDefaults = .standard,
        checker: Checker = .shared
    ) async throws {
        guard let host = url.host?.lowercased(), openAIHosts.contains(host),
              await route(url) == .direct else { return }
        try await requireDirect(traceHost: host, defaults: defaults, checker: checker)
    }

    /// Before Claude Code is started: checked when it would reach any
    /// Anthropic host direct (the first such host is asked). `environment` is
    /// the one it is started with (`SystemProxy.claudeLaunch`: the app's own
    /// proxy variables, or the system proxy with the hosts a PAC sends direct
    /// in `NO_PROXY`, or the SOCKS relay).
    static func checkClaude(
        environment: [String: String],
        settingsEnvironment: [String: String] = claudeSettingsProxyEnvironment(base: ProcessInfo.processInfo.environment),
        defaults: UserDefaults = .standard,
        checker: Checker = .shared
    ) async throws {
        switch claudeRoute(environment: environment, settingsEnvironment: settingsEnvironment) {
        case .proxied:
            return
        case let .direct(host):
            try await requireDirect(traceHost: host, defaults: defaults, checker: checker)
        case .unsure:
            // It may go direct, but no host is surely direct to check through.
            if requiresProxy(defaults) { throw Paused(reason: .proxyNotDetected) }
            guard isEnabled(defaults) else { return }
            throw Paused(reason: .unconfirmed)
        }
    }

    enum ClaudeRoute: Equatable {
        /// Every Anthropic host goes through a proxy Claude Code can use.
        case proxied
        /// This host goes direct under any reading of the bypass list: check it.
        case direct(String)
        /// Some host may go direct, but none surely does.
        case unsure
    }

    /// How Claude Code reaches Anthropic, judged by the proxy it really ends up
    /// with: the environment it is started with, with the proxy keys of its
    /// own `settings.json` `env` on top (Claude Code applies those over its
    /// environment; a proxy set only there is common). Claude Code follows
    /// `HTTPS_PROXY` / `HTTP_PROXY` (either case), no SOCKS or `ALL_PROXY`.
    /// With such a proxy a host goes direct only when the bypass list
    /// (`NO_PROXY` and `no_proxy` together) names it. How Claude Code reads an
    /// entry such as `.api.anthropic.com` or `*.anthropic.com` is not settled
    /// (three cross-review rounds read its code differently), so both ways
    /// count: a host that may go direct under any reading is not let through
    /// unchecked, and the anonymous check goes only to a host that goes direct
    /// under every reading, never to one the user's settings may proxy.
    static func claudeRoute(environment: [String: String], settingsEnvironment: [String: String]) -> ClaudeRoute {
        let effective = environment.merging(settingsEnvironment) { _, setting in setting }
        let proxied = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"].contains {
            !(effective[$0]?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty
        }
        guard proxied else { return .direct(SystemProxy.claudeHosts[0]) }
        let bypass = ["no_proxy", "NO_PROXY"].compactMap { effective[$0] }.joined(separator: ",")
        if let host = SystemProxy.claudeHosts.first(where: { bypassSurely(host: $0, list: bypass) }) { return .direct(host) }
        return SystemProxy.claudeHosts.contains { bypassPossibly(host: $0, list: bypass) } ? .unsure : .proxied
    }

    private static func bypassEntries(_ list: String) -> [String] {
        list.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { raw in
            var entry = raw.lowercased()
            if !entry.hasPrefix("["), let colon = entry.lastIndex(of: ":") {
                // Only an entry for 443 (or no port) concerns these https hosts.
                guard entry[entry.index(after: colon)...] == "443" else { return nil }
                entry = String(entry[..<colon])
            }
            return entry.isEmpty ? nil : entry
        }
    }

    /// Bypassed under every reading: `*`, or the host itself.
    static func bypassSurely(host: String, list: String) -> Bool {
        let host = host.lowercased()
        return bypassEntries(list).contains { $0 == "*" || $0 == host }
    }

    /// Bypassed under some reading: also a domain of it, with or without a
    /// leading `.` / `*.`.
    static func bypassPossibly(host: String, list: String) -> Bool {
        let host = host.lowercased()
        return bypassEntries(list).contains { entry in
            if entry == "*" { return true }
            var domain = Substring(entry)
            if domain.hasPrefix("*.") { domain = domain.dropFirst(2) } else if domain.hasPrefix(".") { domain = domain.dropFirst() }
            return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
        }
    }

    static let proxyEnvironmentNames = [
        "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy",
    ]

    /// The proxy variables in Claude Code's own `settings.json` `env`
    /// (`$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`).
    /// Only those keys are read; nothing is kept or logged.
    static func claudeSettingsProxyEnvironment(base: [String: String]) -> [String: String] {
        let url = DiagnosticCollector.claudeSettingsURL(environment: base)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any]
        else { return [:] }
        var found: [String: String] = [:]
        for name in proxyEnvironmentNames {
            if let value = env[name] as? String { found[name] = value }
        }
        return found
    }

    // MARK: - The check itself

    /// Answers per host, valid for one network (`networkFingerprint`): a
    /// supported country for 10 minutes, anything that pauses for 1 minute, so
    /// a proxy turned back on is seen by the next read. One check per host at
    /// a time; callers arriving meanwhile share its answer.
    actor Checker {
        static let shared = Checker()

        private struct Entry {
            let region: String?
            let checkedAt: Date
            let network: String
        }

        private var entries: [String: Entry] = [:]
        private var inFlight: [String: Task<String?, Never>] = [:]
        private let fetch: @Sendable (String) async -> String?
        private let fingerprint: @Sendable () -> String
        private let now: @Sendable () -> Date

        init(
            fetch: @escaping @Sendable (String) async -> String? = { await EgressCheck.fetchRegion(host: $0) },
            fingerprint: @escaping @Sendable () -> String = { EgressCheck.networkFingerprint() },
            now: @escaping @Sendable () -> Date = Date.init
        ) {
            self.fetch = fetch
            self.fingerprint = fingerprint
            self.now = now
        }

        func region(through host: String) async -> String? {
            let network = fingerprint()
            if let entry = entries[host], entry.network == network {
                let age = now().timeIntervalSince(entry.checkedAt)
                let lifetime = entry.region.map { !EgressCheck.unsupportedRegions.contains($0) } == true
                    ? EgressCheck.supportedLifetime : EgressCheck.pausedLifetime
                if age >= 0, age < lifetime { return entry.region }
            }
            if let running = inFlight[host] { return await running.value }
            let fetch = self.fetch
            let task = Task { await fetch(host) }
            inFlight[host] = task
            let region = await task.value
            inFlight[host] = nil
            entries[host] = Entry(region: region, checkedAt: now(), network: network)
            return region
        }
    }

    /// The two-letter country in a trace body, or nil (unknown `XX`, Tor's
    /// `T1`, absent).
    static func traceRegion(_ body: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) where line.hasPrefix("loc=") {
            let value = line.dropFirst(4).trimmingCharacters(in: .whitespaces).uppercased()
            guard value.count == 2, value.allSatisfy({ $0.isASCII && $0.isLetter }), value != "XX" else { return nil }
            return value
        }
        return nil
    }

    /// One anonymous trace request on a session with every proxy off (the
    /// direct route), no cookie store, no cache, no credential store, no
    /// redirect followed; at most 4 KiB read.
    static func fetchRegion(host: String) async -> String? {
        #if DEBUG
        // UI acceptance builds: show a paused card without a network request.
        if let forced = ProcessInfo.processInfo.environment["VIBE_USAGE_EGRESS_TEST_REGION"] {
            return forced == "none" ? nil : forced
        }
        #endif
        guard let url = URL(string: "https://\(host)/cdn-cgi/trace") else { return nil }
        let configuration = traceConfiguration()
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBodyBytes { return nil }
            }
            return traceRegion(String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    static func traceConfiguration() -> URLSessionConfiguration {
        let configuration = SystemProxy.configuration(for: .direct)
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    /// The Mac's network addresses, hashed: joining another network or a TUN
    /// adapter coming or going changes it, and with it every cached answer.
    /// Loopback and IPv6 link-local addresses are left out (AirDrop's
    /// interfaces come and go with link-local addresses only).
    static func networkFingerprint() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "" }
        defer { freeifaddrs(head) }
        var entries: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard let address = pointer.pointee.ifa_addr, flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if family == AF_INET6, text.lowercased().hasPrefix("fe80") { continue }
            entries.append("\(String(cString: pointer.pointee.ifa_name))|\(family)|\(text)")
        }
        return fingerprint(of: entries)
    }

    static func fingerprint(of entries: [String]) -> String {
        let digest = SHA256.hash(data: Data(entries.sorted().joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
