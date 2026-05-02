import Foundation
import Security

/// Fetches Claude Code rate limits from Anthropic's OAuth usage API.
///
/// Token discovery falls back through:
///   1. `~/.claude/.credentials.json` (preferred — silent)
///   2. macOS Keychain item `Claude Code-credentials` (triggers one-time
///      "Always Allow" prompt the first time we read another app's item)
///
/// Both stores hold either the new shape `{claudeAiOauth: {accessToken, expiresAt}}`
/// or the legacy `{accessToken, expiresAt}` shape — we accept both.
enum ClaudeRateLimitReader {

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private static let oauthBetaHeader = "oauth-2025-04-20"

    /// A dedicated session prevents URLSession.shared's HTTP/2 connection pool
    /// from getting wedged across long-lived menu-bar app sessions — we observed
    /// indefinite hangs (until the per-request timeout) on URLSession.shared
    /// even though `curl` against the same endpoint returned in <1s.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    static func read() async -> ProviderRateLimit {
        print("[rate-limit] ClaudeRateLimitReader.read() entered")
        guard let token = await accessToken() else {
            print("[rate-limit] no access token (file + keychain both failed)")
            return .init(provider: .claudeCode, status: .unauthorized, fetchedAt: Date())
        }
        print("[rate-limit] got access token (length=\(token.count)), calling /api/oauth/usage")

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            print("[rate-limit] request finished in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            guard let http = response as? HTTPURLResponse else {
                print("[rate-limit] invalid response (not HTTPURLResponse)")
                return .init(provider: .claudeCode, status: .error("invalid response"), fetchedAt: Date())
            }
            print("[rate-limit] HTTP \(http.statusCode), bodyBytes=\(data.count)")
            if http.statusCode == 401 || http.statusCode == 403 {
                return .init(provider: .claudeCode, status: .unauthorized, fetchedAt: Date())
            }
            guard (200..<300).contains(http.statusCode) else {
                return .init(provider: .claudeCode, status: .error("HTTP \(http.statusCode)"), fetchedAt: Date())
            }

            return decode(data: data)
        } catch {
            print("[rate-limit] URLSession threw: \(error)")
            return .init(provider: .claudeCode, status: .error(error.localizedDescription), fetchedAt: Date())
        }
    }

    // MARK: - Token discovery

    private static func accessToken() async -> String? {
        if let fromFile = readCredentialsFile() {
            print("[rate-limit] token resolved from ~/.claude/.credentials.json")
            return fromFile
        }
        print("[rate-limit] credentials file missing or unreadable, falling back to keychain")
        return await readKeychainAsync()
    }

    private static func readCredentialsFile() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: url),
              let token = parseToken(from: data) else { return nil }
        return token
    }

    private static func readKeychainAsync() async -> String? {
        // SecItemCopyMatching can block while macOS shows the user prompt;
        // run it off the main actor so the popover stays responsive.
        await Task.detached(priority: .userInitiated) {
            readKeychainSync()
        }.value
    }

    private static func readKeychainSync() -> String? {
        print("[rate-limit] SecItemCopyMatching: about to call (will trigger keychain prompt if no ACL)")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let statusName = describeStatus(status)
        print("[rate-limit] SecItemCopyMatching returned status=\(status) (\(statusName))")
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        if let token = parseToken(from: data) {
            print("[rate-limit] keychain token parsed ok (length=\(token.count))")
            return token
        }
        print("[rate-limit] keychain item retrieved but parseToken failed")
        return nil
    }

    /// Translate common Security framework status codes into readable names so
    /// log lines tell us at a glance whether it's "user denied", "no item", or "wrong ACL".
    private static func describeStatus(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess:               return "success"
        case errSecItemNotFound:          return "errSecItemNotFound — no keychain item with that service name"
        case errSecAuthFailed:            return "errSecAuthFailed — authorization failed"
        case errSecUserCanceled:          return "errSecUserCanceled — user dismissed the prompt"
        case errSecInteractionNotAllowed: return "errSecInteractionNotAllowed — not allowed to prompt the user"
        case errSecMissingEntitlement:    return "errSecMissingEntitlement — app needs keychain entitlement"
        default:                          return "unknown"
        }
    }

    private static func parseToken(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // New shape: { claudeAiOauth: { accessToken, expiresAt } }
        if let oauth = obj["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String,
           !token.isEmpty {
            if let expiresAt = oauth["expiresAt"], !isExpired(expiresAt) {
                return token
            }
            // Field absent → trust the token; caller will surface a 401 if it's stale.
            if oauth["expiresAt"] == nil { return token }
            return nil
        }

        // Legacy shape: { accessToken, expiresAt }
        if let token = obj["accessToken"] as? String, !token.isEmpty {
            if let expiresAt = obj["expiresAt"], !isExpired(expiresAt) {
                return token
            }
            if obj["expiresAt"] == nil { return token }
            return nil
        }
        return nil
    }

    /// `expiresAt` is sometimes ms-since-epoch (Number), sometimes ISO8601 (String).
    private static func isExpired(_ raw: Any) -> Bool {
        let expiry: Date?
        if let ms = raw as? Double {
            expiry = Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms)
        } else if let str = raw as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiry = formatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)
        } else {
            expiry = nil
        }
        guard let expiry else { return false }
        return expiry < Date()
    }

    // MARK: - Response decoding

    private static func decode(data: Data) -> ProviderRateLimit {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .init(provider: .claudeCode, status: .error("malformed JSON"), fetchedAt: Date())
        }
        let fiveHourDur: TimeInterval = 5 * 3600
        let sevenDayDur: TimeInterval = 7 * 86_400
        let opus = parseTier(obj["seven_day_opus"], duration: sevenDayDur)
        let sonnet = parseTier(obj["seven_day_sonnet"], duration: sevenDayDur)
        // Claude's OAuth usage endpoint doesn't expose plan_type directly,
        // but Max-tier subscriptions are the only ones with the per-model
        // sub-quotas. Use that as a soft signal.
        let planLabel: String? = (opus != nil || sonnet != nil) ? "Max" : nil

        return ProviderRateLimit(
            provider: .claudeCode,
            fiveHour: parseTier(obj["five_hour"], duration: fiveHourDur),
            sevenDay: parseTier(obj["seven_day"], duration: sevenDayDur),
            sevenDayOpus: opus,
            sevenDaySonnet: sonnet,
            extraUsage: parseExtraUsage(obj["extra_usage"]),
            planLabel: planLabel,
            status: .ok,
            fetchedAt: Date()
        )
    }

    private static func parseTier(_ raw: Any?, duration: TimeInterval) -> RateLimitWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        let utilization: Double
        if let v = dict["utilization"] as? Double {
            utilization = v
        } else if let v = dict["used_percentage"] as? Double {
            utilization = v
        } else {
            return nil
        }

        var resetsAt: Date?
        if let str = dict["resets_at"] as? String {
            let isoFractional = ISO8601DateFormatter()
            isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = isoFractional.date(from: str) ?? ISO8601DateFormatter().date(from: str)
        } else if let secs = dict["resets_at"] as? Double {
            resetsAt = Date(timeIntervalSince1970: secs)
        }

        return RateLimitWindow(utilization: utilization, resetsAt: resetsAt, windowDuration: duration)
    }

    private static func parseExtraUsage(_ raw: Any?) -> ExtraUsage? {
        guard let dict = raw as? [String: Any] else { return nil }
        // Real API uses `monthly_limit` / `used_credits`; older docs/clients
        // referenced `limit` / `spend`. Accept both names in case the schema
        // shifts again so we don't silently lose the data.
        let limit = (dict["monthly_limit"] as? Double) ?? (dict["limit"] as? Double) ?? 0
        let spend = (dict["used_credits"] as? Double) ?? (dict["spend"] as? Double) ?? 0
        return ExtraUsage(
            isEnabled: (dict["is_enabled"] as? Bool) ?? false,
            spend: spend,
            limit: limit
        )
    }
}
