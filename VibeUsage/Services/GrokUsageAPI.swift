import CryptoKit
import Foundation

/// Fetches Grok subscription quota live from the CLI-proxy billing endpoint
/// the official Grok CLI polls (`GET {cli_chat_proxy}/billing?format=credits`),
/// authenticated with the OAuth token `grok login` already keeps in
/// `~/.grok/auth.json`.
///
/// Same contract as `CodexUsageAPI`: a plain-file token read, no keychain, no
/// prompts, no rewrite of the CLI's credentials, nothing uploaded to the
/// Vibe Usage backend. The endpoint is the SuperGrok / X Premium+ weekly
/// shared pool, not the metered developer API (RPS/TPM). API-key-only logins
/// have no `auth.json` session and are treated as absent.
///
/// `GrokRateLimitReader` stays as the offline fallback: the coordinator paints
/// the last account-scoped live cache instantly, then replaces it with the
/// live response (or a newer `unified.jsonl` billing event when the network
/// is unavailable).
enum GrokUsageAPI {

    /// Why a live fetch produced no snapshot. The coordinator maps these to
    /// different fallbacks: `unauthorized` surfaces a re-login affordance,
    /// `notApplicable` collapses the card (team / no consumer pool),
    /// everything else degrades to the JSONL scan.
    enum FetchError: RateLimitFetchError {
        case notLoggedIn        // no auth.json / no OAuth session (API-key-only)
        case unauthorized       // token rejected even after re-reading auth.json
        case notApplicable      // authenticated but no consumer quota (403)
        case transport(Error)
        case badResponse(Int)
        case unparseable

        var rateLimitFailure: RateLimitFetchFailure {
            switch self {
            case .notLoggedIn: return .absent
            case .unauthorized: return .unauthorized
            case .notApplicable: return .notApplicable
            case .transport, .badResponse, .unparseable: return .transient
            }
        }
    }

    // MARK: - Fetch

    static func fetch(now: Date = Date()) async throws -> ProviderRateLimit {
        guard var auth = loadAuth() else { throw FetchError.notLoggedIn }
        var endpoint = billingURL()

        var (data, status) = try await send(
            url: endpoint,
            token: auth.accessToken,
            userID: auth.userID,
            timeout: requestTimeout
        )

        // The CLI rotates this token routinely, so a 401 usually means our copy
        // is outdated, not that the user logged out. Re-read auth.json once and
        // retry. We deliberately do NOT run the OAuth refresh grant ourselves —
        // rewriting the CLI's credential file from a GUI app isn't worth the
        // risk, and the CLI refreshes on its own next run.
        if status == 401, let fresh = loadAuth(), fresh != auth {
            auth = fresh
            endpoint = billingURL()
            (data, status) = try await send(
                url: endpoint,
                token: fresh.accessToken,
                userID: fresh.userID,
                timeout: requestTimeout
            )
        }
        if status == 401 { throw FetchError.unauthorized }
        if status == 403 { throw FetchError.notApplicable }
        guard status == 200 else { throw FetchError.badResponse(status) }

        guard var snapshot = parseCreditsResponse(data, now: now) else {
            throw FetchError.unparseable
        }
        try Task.checkCancellation()

        if snapshot.status == .ok, snapshot.planLabel == nil,
           let plan = await fetchPlanLabel(auth: auth) {
            snapshot.planLabel = plan
        }

        if let scope = cacheScope(accountID: auth.userID, billingURL: endpoint) {
            cache(snapshot, scope: scope)
        }
        return snapshot
    }

    // MARK: - Transport

    private static let maxAttempts = 3
    private static let requestTimeout: TimeInterval = 10
    private static let settingsTimeout: TimeInterval = 2

    private static func send(
        url: URL,
        token: String,
        userID: String?,
        timeout: TimeInterval
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeUsage/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")
        if let userID, !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "x-userid")
        }

        var lastError: Error?
        var lastStatus = 0
        var lastData = Data()
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                try await Task.sleep(for: .milliseconds(500 * (1 << (attempt - 2))))
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !isRetryable(status: status) || attempt == maxAttempts {
                    return (data, status)
                }
                (lastData, lastStatus) = (data, status)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !isRetryable(error: error) || attempt == maxAttempts {
                    throw FetchError.transport(error)
                }
                lastError = error
            }
        }
        if let lastError { throw FetchError.transport(lastError) }
        return (lastData, lastStatus)
    }

    /// Retry 5xx and the request-timeout family; 4xx (including 401/403/429)
    /// are deterministic answers, not transient failures.
    private static func isRetryable(status: Int) -> Bool {
        status >= 500 || status == 408 || status == 425
    }

    private static func isRetryable(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Plan name lives on `/v1/settings`, not the credits payload. Best-effort
    /// and short-timeout so a stuck settings call cannot delay an already
    /// fetched weekly percentage.
    private static func fetchPlanLabel(auth: AuthInfo) async -> String? {
        do {
            let (data, status) = try await send(
                url: settingsURL(),
                token: auth.accessToken,
                userID: auth.userID,
                timeout: settingsTimeout
            )
            guard status == 200 else { return nil }
            return parseSettingsPlanLabel(data)
        } catch {
            return nil
        }
    }

    // MARK: - Credentials (~/.grok/auth.json)

    struct AuthInfo: Equatable {
        var accessToken: String
        var userID: String?
    }

    /// Honor GROK_HOME (some users relocate ~/.grok), mirroring the CLI.
    static var grokHome: URL {
        if let custom = ProcessInfo.processInfo.environment["GROK_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok")
    }

    private static func loadAuth() -> AuthInfo? {
        guard let data = try? Data(contentsOf: grokHome.appendingPathComponent("auth.json")) else {
            return nil
        }
        return parseAuthFile(data)
    }

    /// `auth.json` is keyed by OIDC issuer URL. Prefer SuperGrok
    /// `https://auth.x.ai::<client-id>` entries, then the legacy
    /// `https://accounts.x.ai/sign-in` session, then any dict with a `key`.
    /// API-key-only logins never write this file — that's `nil` here.
    static func parseAuthFile(_ data: Data) -> AuthInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var ranked: [(rank: Int, expires: TimeInterval, info: AuthInfo)] = []
        for (key, value) in obj {
            guard let entry = value as? [String: Any],
                  let token = entry["key"] as? String, !token.isEmpty
            else { continue }

            let rank: Int
            let lowered = key.lowercased()
            if lowered.hasPrefix("https://auth.x.ai") {
                rank = 0
            } else if lowered.contains("accounts.x.ai") {
                rank = 1
            } else {
                rank = 2
            }

            let userID = stringValue(entry["user_id"]) ?? stringValue(entry["principal_id"])
            let expires = expirySortKey(entry["expires_at"])
            ranked.append((rank, expires, AuthInfo(accessToken: token, userID: userID)))
        }

        ranked.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.expires > $1.expires
        }
        return ranked.first?.info
    }

    private static func expirySortKey(_ raw: Any?) -> TimeInterval {
        if let number = numberValue(raw) { return number }
        if let string = raw as? String, let date = parseISO8601(string) {
            return date.timeIntervalSince1970
        }
        return 0
    }

    // MARK: - Endpoint URL

    static let defaultBaseURL = "https://cli-chat-proxy.grok.com/v1"

    private static func billingURL() -> URL {
        billingURL(base: configuredBaseURL())
    }

    private static func settingsURL() -> URL {
        settingsURL(base: configuredBaseURL())
    }

    private static func configuredBaseURL() -> String {
        let configURL = grokHome.appendingPathComponent("config.toml")
        let configured = (try? String(contentsOf: configURL, encoding: .utf8))
            .flatMap(parseCliChatProxyBaseURL)
        return configured ?? defaultBaseURL
    }

    static func billingURL(base: String) -> URL {
        let normalized = normalizeBase(base)
        return URL(string: normalized + "/billing?format=credits")
            ?? URL(string: defaultBaseURL + "/billing?format=credits")!
    }

    static func settingsURL(base: String) -> URL {
        let normalized = normalizeBase(base)
        return URL(string: normalized + "/settings")
            ?? URL(string: defaultBaseURL + "/settings")!
    }

    private static func normalizeBase(_ base: String) -> String {
        var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = defaultBaseURL }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// Read `cli_chat_proxy_base_url` from the `[endpoints]` table only —
    /// a same-named key in another table must not leak out.
    static func parseCliChatProxyBaseURL(_ toml: String) -> String? {
        var inEndpoints = false
        let pattern = /cli_chat_proxy_base_url\s*=\s*"([^"]+)"/
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEndpoints = line == "[endpoints]"
                continue
            }
            guard inEndpoints, let match = line.prefixMatch(of: pattern) else { continue }
            return String(match.1)
        }
        return nil
    }

    // MARK: - Response parsing

    /// Live REST body is `{ "config": { camelCase BillingConfig } }`. The CLI's
    /// unified-log wrapper also puts `subscriptionTier` next to `config`.
    static func parseCreditsResponse(_ data: Data, now: Date = Date()) -> ProviderRateLimit? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseCreditsObject(obj, now: now)
    }

    static func parseCreditsObject(_ obj: [String: Any], now: Date = Date()) -> ProviderRateLimit? {
        let config: [String: Any]
        if let nested = obj["config"] as? [String: Any] {
            config = nested
        } else if obj["creditUsagePercent"] != nil
                    || obj["currentPeriod"] != nil
                    || obj["billingPeriodEnd"] != nil
                    || obj["monthlyLimit"] != nil {
            config = obj
        } else {
            return nil
        }

        let planLabel = stringValue(obj["subscriptionTier"])
            ?? stringValue(obj["subscription_tier"])
            ?? stringValue(config["subscriptionTier"])

        return parseCreditsConfig(config, planLabel: planLabel, now: now)
    }

    static func parseCreditsConfig(
        _ config: [String: Any],
        planLabel: String?,
        now: Date
    ) -> ProviderRateLimit {
        let period = config["currentPeriod"] as? [String: Any]
        let start = parseISO8601(
            stringValue(period?["start"]) ?? stringValue(config["billingPeriodStart"])
        )
        let end = parseISO8601(
            stringValue(period?["end"]) ?? stringValue(config["billingPeriodEnd"])
        )

        var utilization: Double?
        if let percent = numberValue(config["creditUsagePercent"]) {
            utilization = percent
        } else if let used = centsValue(config["used"]),
                  let limit = centsValue(config["monthlyLimit"]),
                  limit > 0 {
            utilization = used / limit * 100
        } else if let used = centsValue(config["onDemandUsed"]),
                  let cap = centsValue(config["onDemandCap"]),
                  cap > 0 {
            utilization = used / cap * 100
        } else if period != nil || end != nil {
            // A parseable current period without a percent is zero usage, not
            // "no data" — proto3 omits default scalars.
            utilization = 0
        }

        var duration: TimeInterval?
        if let start, let end, end > start {
            duration = end.timeIntervalSince(start)
        } else if let type = stringValue(period?["type"]) {
            if type.contains("MONTHLY") {
                duration = 30 * 86_400
            } else if type.contains("WEEKLY") {
                duration = 7 * 86_400
            }
        }

        var sevenDay: RateLimitWindow?
        if let utilization {
            if let end, end <= now {
                debugLog("[rate-limit] grok weekly window expired \(Int(-end.timeIntervalSince(now)))s ago — dropping stale slot")
            } else {
                sevenDay = RateLimitWindow(
                    utilization: utilization,
                    resetsAt: end,
                    windowDuration: duration
                )
            }
        }

        var extra: ExtraUsage?
        if let cap = centsValue(config["onDemandCap"]), cap > 0 {
            let used = centsValue(config["onDemandUsed"]) ?? 0
            extra = ExtraUsage(
                isEnabled: true,
                spend: used / 100,
                limit: cap / 100
            )
        }

        return ProviderRateLimit(
            provider: .grok,
            sevenDay: sevenDay,
            extraUsage: extra,
            planLabel: formatPlanLabel(planLabel),
            status: sevenDay == nil ? .noData : .ok,
            fetchedAt: now,
            dataAsOf: now
        )
    }

    static func parseSettingsPlanLabel(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let raw = stringValue(obj["subscription_tier_display"])
            ?? stringValue(obj["subscriptionTierDisplay"])
            ?? stringValue(obj["subscription_tier"])
            ?? stringValue(obj["subscriptionTier"])
        return formatPlanLabel(raw)
    }

    /// Keep already-pretty labels ("SuperGrok Plus") as-is; title-case a
    /// lowercase/enum token the way Codex does for `plan_type`.
    static func formatPlanLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(where: { $0.isUppercase }) { return trimmed }
        return trimmed.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = parseISO8601Once(raw) { return date }
        // Grok emits RFC 3339 with 6 fractional digits and `+00:00`.
        // ISO8601DateFormatter is picky about both; normalize and retry.
        return parseISO8601Once(normalizeISO8601(raw))
    }

    private static func parseISO8601Once(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        if let date = basic.date(from: raw) { return date }
        if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(raw, strategy: Date.ISO8601FormatStyle())
    }

    private static func normalizeISO8601(_ raw: String) -> String {
        var s = raw
        if let range = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let fraction = s[range]
            if fraction.count > 4 {
                s.replaceSubrange(range, with: String(fraction.prefix(4)))
            }
        }
        if s.hasSuffix("+00:00") {
            s = String(s.dropLast(6)) + "Z"
        }
        return s
    }

    static func numberValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }

    static func stringValue(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        return value
    }

    /// proto3 JSON omits zero-valued scalars, so a `$0` Cent arrives as `{}`.
    static func centsValue(_ raw: Any?) -> Double? {
        guard let dict = raw as? [String: Any] else { return nil }
        if dict["val"] == nil { return 0 }
        return numberValue(dict["val"])
    }

    // MARK: - Snapshot cache (~/.vibe-usage/grok-rate-limits.json)

    private struct CachedSnapshot: Codable {
        struct Window: Codable {
            var utilization: Double
            var resetsAt: Date?
            var windowDuration: TimeInterval?
        }

        var scopeHash: String
        var fetchedAt: Date
        var sevenDay: Window?
        var planLabel: String?
    }

    static var cacheFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe-usage")
            .appendingPathComponent("grok-rate-limits.json")
    }

    /// Stable, non-reversible identity for the quota namespace. A user id is
    /// required: without one we cannot prove that a prior snapshot belongs to
    /// the current login, so correctness wins over instant paint.
    static func cacheScope(accountID: String?, billingURL: URL) -> String? {
        guard let accountID, !accountID.isEmpty else { return nil }
        let material = Data("\(billingURL.absoluteString)\u{0}\(accountID)".utf8)
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func currentCacheScope() -> String? {
        guard let auth = loadAuth() else { return nil }
        return cacheScope(accountID: auth.userID, billingURL: billingURL())
    }

    static func cache(
        _ snapshot: ProviderRateLimit,
        scope: String,
        to url: URL = cacheFileURL
    ) {
        guard snapshot.status == .ok else {
            if snapshot.status == .noData {
                removeCachedSnapshot(scope: scope, from: url)
            }
            return
        }
        func window(_ w: RateLimitWindow?) -> CachedSnapshot.Window? {
            w.map { .init(utilization: $0.utilization, resetsAt: $0.resetsAt, windowDuration: $0.windowDuration) }
        }
        let cached = CachedSnapshot(
            scopeHash: scope,
            fetchedAt: snapshot.dataAsOf ?? Date(),
            sevenDay: window(snapshot.sevenDay),
            planLabel: snapshot.planLabel
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cached) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func removeCachedSnapshot(scope: String, from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode(CachedSnapshot.self, from: data),
              cached.scopeHash == scope
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func cachedSnapshot(now: Date = Date()) -> ProviderRateLimit? {
        guard let scope = currentCacheScope() else { return nil }
        return cachedSnapshot(from: cacheFileURL, now: now, scope: scope)
    }

    static func cachedSnapshot(
        from url: URL,
        now: Date = Date(),
        scope: String
    ) -> ProviderRateLimit? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode(CachedSnapshot.self, from: data) else { return nil }
        guard cached.scopeHash == scope else { return nil }

        let maxCacheAge: TimeInterval = 7 * 86_400
        let cacheAge = now.timeIntervalSince(cached.fetchedAt)
        guard cacheAge >= 0, cacheAge <= maxCacheAge else { return nil }

        guard let stored = cached.sevenDay else { return nil }
        if let resetsAt = stored.resetsAt, resetsAt <= now { return nil }

        return ProviderRateLimit(
            provider: .grok,
            sevenDay: RateLimitWindow(
                utilization: stored.utilization,
                resetsAt: stored.resetsAt,
                windowDuration: stored.windowDuration
            ),
            planLabel: cached.planLabel,
            status: .ok,
            fetchedAt: now,
            dataAsOf: cached.fetchedAt
        )
    }
}
