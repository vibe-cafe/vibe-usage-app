import Foundation

/// Provider-neutral meaning of a failed live refresh. Concrete transports
/// conform to `RateLimitFetchError` so the coordinator can decide whether a
/// card stays neutral, requests login, or offers retry without knowing each
/// provider's private error enum.
enum RateLimitFetchFailure: Equatable {
    case absent
    case notApplicable
    case unauthorized
    case transient
}

protocol RateLimitFetchError: Error {
    var rateLimitFailure: RateLimitFetchFailure { get }
}

/// One subscription window (e.g. 5h or 7d) for a single provider.
struct RateLimitWindow: Equatable {
    var utilization: Double  // 0-100
    var resetsAt: Date?
    /// Total length of the rolling window (5 hours, 7 days, etc.). Used to
    /// compute "% time elapsed" for the secondary bar by combining with `resetsAt`.
    var windowDuration: TimeInterval?
}

/// A provider-neutral quota meter. New providers are not required to expose
/// Codex's exact 5h/7d shape; the desktop can render the first two important
/// meters and summarize the remainder without changing its card layout.
struct RateLimitMeter: Equatable, Identifiable {
    var id: String
    var label: String
    var window: RateLimitWindow
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
    enum Provider: String, CaseIterable, Codable {
        case codex = "codex"
        case claudeCode = "claude-code"
        case kimiCode = "kimi-code"
        case zCode = "zcode"
        case grok = "grok"
        case cursor = "cursor"
        // The OpenCode *Go* subscription, not the OpenCode CLI as a whole: the
        // quota endpoint only answers for Go accounts, so the card is named
        // after the plan users bought.
        case opencode = "opencode"

        var displayName: String {
            switch self {
            case .codex: return "Codex"
            case .claudeCode: return "Claude"
            case .kimiCode: return "Kimi Code"
            case .zCode: return "ZCode"
            case .grok: return "Grok"
            case .cursor: return "Cursor"
            case .opencode: return "OpenCode Go"
            }
        }
    }

    enum Status: Equatable {
        case ok
        case noData                    // provider isn't installed or has no recent activity
        case disabled                  // user hasn't opted into this provider's monitoring yet
        case unauthorized              // tried to fetch but token missing/expired/keychain denied
        case retryableError             // concrete read failed; UI supplies localized retry copy
        case error(String)
    }

    var id: String { provider.rawValue }
    var provider: Provider
    /// Preferred provider-neutral representation. Existing native Codex and
    /// Claude readers continue filling their typed fields below; CLI-backed
    /// providers can populate this collection directly.
    var meters: [RateLimitMeter] = []
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

    /// Why a source that *did* answer had no window to draw, when it can say.
    ///
    /// Codex's live usage endpoint reports enforced windows exhaustively and
    /// its `rate_limit` object carries `allowed` / `limit_reached`, so an
    /// answer without any window is a fact — "used up for this period" or
    /// "nothing enforced right now" — not a read failure. Every other source
    /// (session JSONL, on-disk cache, the other providers) cannot tell the two
    /// apart from "that product has no data here", so it leaves this nil and
    /// the card stays neutral rather than guessing.
    enum EmptyReason: Equatable {
        /// `limit_reached == true`: this period's quota is consumed.
        case limitReached
        /// The endpoint answered without enforcing any window.
        case noWindow
        /// The endpoint answered but the account doesn't own the subscription
        /// (OpenCode Go returns 403 `EntitlementError` for a Zen/free key).
        /// A retry cannot change it, so the card must not offer one.
        case notEntitled
    }

    var emptyReason: EmptyReason?
}
