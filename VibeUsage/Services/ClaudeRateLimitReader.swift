import Foundation

/// Reads Claude Code's rate limits from the local capture file written by our
/// statusline wrapper (see `StatuslineHook`).
///
/// Claude Code pipes a status payload to its configured `statusLine.command` on
/// every render; that payload carries a `rate_limits` object with `five_hour`
/// and `seven_day` windows. The wrapper tees that slice to
/// `~/.vibe-usage/claude-rate-limits.json`. We just read & parse it here — no
/// network, no OAuth token, no keychain. This is the same auth-free, local-file
/// shape as `CodexRateLimitReader`.
///
/// Captured file shape:
/// ```json
/// {
///   "five_hour":  { "used_percentage": 37.0, "resets_at": 1778950000 },
///   "seven_day":  { "used_percentage": 64.0, "resets_at": 1779400000 },
///   "model_id":   "claude-opus-4-7",
///   "captured_at": 1778938491
/// }
/// ```
/// (`resets_at` may also arrive as an ISO-8601 string on some Claude versions;
/// we accept both. Field names mirror claude-hud's reverse-engineered schema.)
enum ClaudeRateLimitReader {

    private static let fiveHourDuration: TimeInterval = 5 * 3600
    private static let sevenDayDuration: TimeInterval = 7 * 86_400

    /// Snapshots older than this are still shown (a slightly stale 5h figure is
    /// more useful than none) but we log it so first-run debugging is easy.
    private static let stalenessThreshold: TimeInterval = 30 * 60

    static func read() -> ProviderRateLimit {
        let url = StatuslineHook.rateLimitFileURL
        debugLog("[rate-limit] ClaudeRateLimitReader.read() -> \(url.path)")

        guard FileManager.default.fileExists(atPath: url.path) else {
            // No capture yet: either the user hasn't enabled the statusline
            // hook, or Claude Code hasn't rendered a statusline since install.
            // `.disabled` keeps the card visible with an "enable" affordance.
            debugLog("[rate-limit] capture file absent — reporting .disabled")
            return .init(provider: .claudeCode, status: .disabled, fetchedAt: nil)
        }

        guard let data = try? Data(contentsOf: url) else {
            return .init(provider: .claudeCode, status: .error("无法读取限额缓存"), fetchedAt: Date())
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .init(provider: .claudeCode, status: .error("限额缓存格式错误"), fetchedAt: Date())
        }

        let fiveHour = parseWindow(obj["five_hour"], duration: fiveHourDuration)
        let sevenDay = parseWindow(obj["seven_day"], duration: sevenDayDuration)

        guard fiveHour != nil || sevenDay != nil else {
            // File exists but no usable windows — e.g. an API/Bedrock session
            // (no subscription limits). Treat as "nothing to show" rather than
            // an error; the card collapses just like Codex `.noData`.
            debugLog("[rate-limit] capture file had no usable windows")
            return .init(provider: .claudeCode, status: .noData, fetchedAt: Date())
        }

        if let capturedAt = (obj["captured_at"] as? Double).map({ Date(timeIntervalSince1970: $0) }) {
            let age = Date().timeIntervalSince(capturedAt)
            if age > stalenessThreshold {
                debugLog("[rate-limit] capture is stale by \(Int(age))s (Claude Code may be idle)")
            }
        }

        return ProviderRateLimit(
            provider: .claudeCode,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            // Subscription-only signal: API/Bedrock sessions never reach here
            // (no windows), so a present window implies a paid plan. We can't
            // distinguish Pro vs Max from this payload, so leave the label nil.
            planLabel: nil,
            status: .ok,
            fetchedAt: Date()
        )
    }

    // MARK: - Parsing

    /// Parse one `{ used_percentage, resets_at }` window. Tolerant of both the
    /// `used_percentage` and legacy `utilization` keys, and of `resets_at` being
    /// epoch seconds (Number) or ISO-8601 (String) — Claude Code's exact shape
    /// is version-dependent and reverse-engineered, so we defend against drift.
    ///
    /// `duration` is the nominal window length (5h / 7d). Claude Code's payload
    /// only gives `resets_at` (no window start), so the "% time elapsed" bar is
    /// an approximation: `elapsed = duration - timeUntil(resets_at)`, which is
    /// accurate while the snapshot is fresh and the period really is that long.
    ///
    /// The one hard failure we guard against: a *stale* capture whose
    /// `resets_at` has already passed. Then `timeUntilReset` clamps to 0 and the
    /// naive formula pins elapsed to 100% (the bug that showed every bar full).
    /// We detect that here and drop `windowDuration` (→ `elapsedPercent` nil →
    /// no time bar) rather than render a confidently-wrong 100%.
    private static func parseWindow(_ raw: Any?, duration: TimeInterval) -> RateLimitWindow? {
        guard let dict = raw as? [String: Any] else { return nil }

        let utilization: Double
        if let v = dict["used_percentage"] as? Double {
            utilization = v
        } else if let v = dict["utilization"] as? Double {
            utilization = v
        } else {
            return nil
        }

        var resetsAt: Date?
        if let secs = dict["resets_at"] as? Double, secs > 0 {
            resetsAt = Date(timeIntervalSince1970: secs)
        } else if let str = dict["resets_at"] as? String, !str.isEmpty {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = iso.date(from: str) ?? ISO8601DateFormatter().date(from: str)
        }

        // Only expose the window length (→ enables the elapsed-time bar) when
        // `resets_at` is still in the future. A stale snapshot whose reset has
        // already passed would otherwise pin the time bar to a wrong 100%.
        let resetInFuture = (resetsAt?.timeIntervalSinceNow ?? -1) > 0
        return RateLimitWindow(
            utilization: utilization,
            resetsAt: resetsAt,
            windowDuration: resetInFuture ? duration : nil
        )
    }
}
