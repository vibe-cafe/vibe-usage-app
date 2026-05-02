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
}
