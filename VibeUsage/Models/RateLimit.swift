import Foundation

/// One subscription window (e.g. 5h or 7d) for a single provider.
struct RateLimitWindow: Equatable {
    var utilization: Double  // 0-100
    var resetsAt: Date?
    /// Total length of the rolling window (5 hours, 7 days, etc.). Used to
    /// compute "% time elapsed" for the secondary bar by combining with `resetsAt`.
    var windowDuration: TimeInterval?
}

/// Pay-as-you-go credits beyond the base subscription quota (Claude only).
struct ExtraUsage: Equatable {
    var isEnabled: Bool
    var spend: Double
    var limit: Double
}

/// Aggregate rate-limit snapshot for one provider. All sub-windows are optional —
/// a provider may report fewer windows depending on plan tier or configuration.
struct ProviderRateLimit: Equatable, Identifiable {
    enum Provider: String {
        case codex = "Codex"
        case claudeCode = "Claude Code"
    }

    enum Status: Equatable {
        case loading                   // first read is in flight; no prior snapshot to show yet
        case ok
        case noData                    // provider isn't installed or has no recent activity
        case disabled                  // user hasn't opted into this provider's monitoring yet
        case unauthorized              // tried to fetch but token missing/expired/keychain denied
        case error(String)
    }

    var id: String { provider.rawValue }
    var provider: Provider
    var fiveHour: RateLimitWindow?
    var sevenDay: RateLimitWindow?
    var sevenDayOpus: RateLimitWindow?     // Claude Max plan only
    var sevenDaySonnet: RateLimitWindow?   // Claude Max plan only
    var extraUsage: ExtraUsage?
    var planLabel: String?                 // e.g. "free", "Plus", "Pro", "Max"
    /// Number of unused manual rate-limit "reset" credits on the account
    /// (Codex only). Each credit lets the user reset one usage window early.
    /// nil = unknown / not applicable (free plan, API-key session, or the
    /// local-file fallback which can't see this server-side value).
    var resetCredits: Int?
    var status: Status
    var fetchedAt: Date?
    /// True while a refresh is in flight. Independent of `status` so a
    /// background refresh (popover reopened, manual "更新数据") can keep the
    /// last-known numbers on screen instead of yanking them out for a spinner —
    /// only a *first-ever* read (no prior snapshot) uses `.loading` for that.
    var isFetching: Bool = false
}
