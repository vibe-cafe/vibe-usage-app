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
    var status: Status
    var fetchedAt: Date?

    /// When the numbers were actually *produced*, as opposed to `fetchedAt`
    /// (when we read them). Live network snapshots set this to now; file-based
    /// snapshots inherit the event/capture timestamp, so the card can say
    /// 「数据截至 N 分钟前」 instead of presenting idle-era data as current.
    var dataAsOf: Date?

    /// Codex only: the usage endpoint reports enforced windows exhaustively,
    /// so a missing 5h window there means the limit is switched off (OpenAI
    /// removed it on 2026-07-12), not "no recent activity". Drives the 5h
    /// placeholder copy. Always false for file-based snapshots, which cannot
    /// tell the two apart.
    var fiveHourNotEnforced: Bool = false

    /// Codex only: available rate-limit reset credits (nil when unknown or 0).
    var resetCreditsCount: Int?
}
