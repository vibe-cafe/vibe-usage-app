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

    static func read() async -> ProviderRateLimit {
        guard let token = await accessToken() else {
            return .init(provider: .claudeCode, status: .unauthorized, fetchedAt: Date())
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .init(provider: .claudeCode, status: .error("invalid response"), fetchedAt: Date())
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .init(provider: .claudeCode, status: .unauthorized, fetchedAt: Date())
            }
            guard (200..<300).contains(http.statusCode) else {
                return .init(provider: .claudeCode, status: .error("HTTP \(http.statusCode)"), fetchedAt: Date())
            }

            return decode(data: data)
        } catch {
            return .init(provider: .claudeCode, status: .error(error.localizedDescription), fetchedAt: Date())
        }
    }

    // MARK: - Token discovery

    private static func accessToken() async -> String? {
        if let fromFile = readCredentialsFile() { return fromFile }
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return parseToken(from: data)
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
        let opus = parseTier(obj["seven_day_opus"])
        let sonnet = parseTier(obj["seven_day_sonnet"])
        // Claude's OAuth usage endpoint doesn't expose plan_type directly,
        // but Max-tier subscriptions are the only ones with the per-model
        // sub-quotas. Use that as a soft signal.
        let planLabel: String? = (opus != nil || sonnet != nil) ? "Max" : nil

        return ProviderRateLimit(
            provider: .claudeCode,
            fiveHour: parseTier(obj["five_hour"]),
            sevenDay: parseTier(obj["seven_day"]),
            sevenDayOpus: opus,
            sevenDaySonnet: sonnet,
            extraUsage: parseExtraUsage(obj["extra_usage"]),
            planLabel: planLabel,
            status: .ok,
            fetchedAt: Date()
        )
    }

    private static func parseTier(_ raw: Any?) -> RateLimitWindow? {
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

        return RateLimitWindow(utilization: utilization, resetsAt: resetsAt)
    }

    private static func parseExtraUsage(_ raw: Any?) -> ExtraUsage? {
        guard let dict = raw as? [String: Any] else { return nil }
        return ExtraUsage(
            isEnabled: (dict["is_enabled"] as? Bool) ?? false,
            spend: (dict["spend"] as? Double) ?? 0,
            limit: (dict["limit"] as? Double) ?? 0
        )
    }
}
