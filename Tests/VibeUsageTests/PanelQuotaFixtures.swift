import Foundation
@testable import VibeUsage

/// Quota readings for the panel renderer's scenes, after the finalized
/// design's sample numbers (131a: Codex 5h 12% / 7d 79%, Claude 5h 36% /
/// 7d 31% / Fable 58%, Cursor mo 41%, Grok 7d 88%, …). Windows are placed
/// relative to the render's clock, so pace, forecasts and resets read the
/// same every time. Only snapshots; no reader runs.
enum PanelQuotas: Sendable {
    /// 131a and 132d: Codex nearly out, Claude and Kimi fast, the rest fine.
    case design
    /// 131e: every subscription on pace.
    case normal
    /// 132a: Codex nearly out, Claude on pace.
    case codexRedClaudeNormal
    /// 132b: Claude fast, Codex on pace.
    case claudeFastCodexNormal
    /// 132c: Kimi on pace too, so the folded pair is 「都正常」.
    case fiveCalm
    /// 132e: used up, sign-in needed, read failed, not on a subscription sign-in.
    case special
    /// 132h, 132i: Claude's Fable nearly out.
    case fableAlert
    /// 132k, 132l: Claude with Fable and pay-as-you-go spend (four rows).
    case claudeExtra
    /// 132m: Cursor's first read still running.
    case cursorLoading
    /// 132n: Cursor's read timed out.
    case cursorReadFailed
    /// 132o: Claude's sign-in was rejected.
    case claudeLoginExpired
    /// 132p: not subscribed to Cursor.
    case cursorNotEntitled
    /// 132q: Claude's live read timed out; the cache is shown.
    case claudeStale
    /// 133d: Claude needs a sign-in, Cursor's read failed.
    case dots
    /// Cursor needs the separate sign-in, or Cursor ended it.
    case cursorSignIn, cursorSignInExpired
    /// Codex paused by the egress check, with and without older numbers.
    case codexPausedKept, codexPausedEmpty
    /// Claude under an organization policy, without and with Desktop's record.
    case claudePolicy, claudePolicyKept
    /// Claude Code not on a subscription sign-in.
    case claudeNonSubscription
    /// Codex says used up without any window.
    case codexExhaustedNoWindow
    /// Grok's weekly reading is past its reset.
    case grokExpired
    /// Claude without a 5h window, with Fable (5h being phased out).
    case claudeWeeklyFable
    /// Claude Pro: 5h and 7d, no Fable.
    case claudePro
    /// The external-test screenshot of 2026-11-28: Codex Pro with 7d only and
    /// behind pace, Claude ahead of pace, Antigravity untouched in both
    /// windows (the longest name with two three-digit numbers), Cursor and
    /// Grok folded.
    case agyCrowded

    func snapshots(now: Date) -> [ProviderRateLimit] {
        let b = Builder(now: now)
        var byProvider = Dictionary(uniqueKeysWithValues: b.design.map { ($0.provider, $0) })
        func set(_ snapshot: ProviderRateLimit) { byProvider[snapshot.provider] = snapshot }

        switch self {
        case .design:
            break
        case .normal:
            set(b.claudeNormal)
            set(b.codexNormal)
        case .codexRedClaudeNormal:
            set(b.claudeNormal)
        case .claudeFastCodexNormal:
            set(b.codexNormal)
        case .fiveCalm:
            set(b.snapshot(.kimiCode, b.window(71, 5, due: 34), b.window(60, 168, due: 52)))
        case .special:
            set(b.snapshot(.codex, b.window(0, 5, due: 40), b.window(79, 168, due: 53)))
            set(b.empty(.claudeCode, status: .unauthorized, failure: .credentialsNotFound))
            set(b.empty(.cursor, status: .retryableError, failure: .endpointTimedOut))
            set(b.empty(.kimiCode, reason: .sessionWithoutPlanLimits))
        case .fableAlert:
            var claude = b.snapshot(.claudeCode, b.window(36, 5, due: 16), b.window(53, 168, due: 39), plan: "Max")
            claude.modelScopedMeters = [b.fable(9, due: 61)]
            set(claude)
        case .claudeExtra:
            var claude = b.claude
            claude.extraUsage = ExtraUsage(isEnabled: true, spend: 18, limit: 100)
            set(claude)
        case .cursorLoading:
            set(ProviderRateLimit(provider: .cursor, status: .noData))
        case .cursorReadFailed:
            var cursor = b.empty(.cursor, status: .retryableError, failure: .endpointTimedOut)
            cursor.planLabel = "Pro"
            set(cursor)
        case .claudeLoginExpired:
            var claude = b.empty(.claudeCode, status: .unauthorized, failure: .credentialsRejected)
            claude.planLabel = "Max"
            set(claude)
        case .cursorNotEntitled:
            set(b.empty(.cursor, reason: .notEntitled))
        case .claudeStale:
            var claude = b.claude
            claude.modelScopedMeters = []
            claude.source = .cache
            claude.liveFailure = .claudeTimedOut
            set(claude)
        case .dots:
            set(b.empty(.claudeCode, status: .unauthorized, failure: .credentialsNotFound))
            set(b.empty(.cursor, status: .retryableError, failure: .endpointTimedOut))
        case .cursorSignIn:
            set(b.empty(.cursor, failure: .signInRequired))
        case .cursorSignInExpired:
            set(b.empty(.cursor, failure: .signInExpired))
        case .codexPausedKept:
            var codex = b.codex
            codex.source = .cache
            codex.liveFailure = .egressRegionUnsupported("CN")
            set(codex)
        case .codexPausedEmpty:
            set(b.empty(.codex, failure: .egressRegionUnsupported("CN")))
        case .claudePolicy:
            set(b.empty(.claudeCode, reason: .nonessentialTrafficDisabled))
        case .claudePolicyKept:
            var claude = b.snapshot(.claudeCode, .init(utilization: 64), .init(utilization: 69), plan: "Max")
            claude.source = .desktopRecord
            claude.liveFailure = .claudeBlockedByPolicy
            set(claude)
        case .claudeNonSubscription:
            set(b.empty(.claudeCode, reason: .sessionWithoutPlanLimits))
        case .codexExhaustedNoWindow:
            set(b.empty(.codex, reason: .limitReached))
        case .grokExpired:
            set(b.snapshot(.grok, nil, .init(utilization: 40, resetsAt: now.addingTimeInterval(-3_600),
                                             windowDuration: 168 * 3_600)))
        case .claudeWeeklyFable:
            var claude = b.snapshot(.claudeCode, nil, b.window(62, 168, due: 55), plan: "Max")
            claude.modelScopedMeters = [b.fable(41, due: 55)]
            set(claude)
        case .claudePro:
            set(b.snapshot(.claudeCode, b.window(58, 5, due: 40), b.window(74, 168, due: 60), plan: "Pro"))
        case .agyCrowded:
            set(b.snapshot(.codex, nil, b.window(53, 168, due: 64), plan: "Pro"))
            set(b.snapshot(.claudeCode, b.window(99, 5, due: 88), b.window(39, 168, due: 21), plan: "Max"))
            set(b.snapshot(.antigravity, .init(utilization: 0), b.window(100, 168, due: 91)))
        }
        return ProviderRateLimit.Provider.allCases.compactMap { byProvider[$0] }
    }

    private struct Builder {
        let now: Date

        /// `remaining` percent left; `due` percent of the window still to go.
        func window(_ remaining: Double, _ hours: Double, due: Double) -> RateLimitWindow {
            RateLimitWindow(utilization: 100 - remaining,
                            resetsAt: now.addingTimeInterval(hours * 3_600 * due / 100),
                            windowDuration: hours * 3_600)
        }

        func snapshot(_ provider: ProviderRateLimit.Provider, _ short: RateLimitWindow?, _ long: RateLimitWindow?,
                      plan: String? = nil) -> ProviderRateLimit {
            var snapshot = ProviderRateLimit(provider: provider, fiveHour: short, sevenDay: long, status: .ok, fetchedAt: now)
            snapshot.planLabel = plan
            snapshot.source = .live
            return snapshot
        }

        func empty(_ provider: ProviderRateLimit.Provider, status: ProviderRateLimit.Status = .noData,
                   reason: ProviderRateLimit.EmptyReason? = nil,
                   failure: ProviderRateLimit.LiveFailure? = nil) -> ProviderRateLimit {
            ProviderRateLimit(provider: provider, status: status, fetchedAt: now, emptyReason: reason, liveFailure: failure)
        }

        func fable(_ remaining: Double, due: Double) -> RateLimitMeter {
            RateLimitMeter(id: "fable", label: "Fable", window: window(remaining, 168, due: due))
        }

        var codex: ProviderRateLimit {
            var codex = snapshot(.codex, window(12, 5, due: 29), window(79, 168, due: 53), plan: "Plus")
            codex.resetCreditsCount = 2
            return codex
        }

        var codexNormal: ProviderRateLimit {
            snapshot(.codex, window(62, 5, due: 29), window(79, 168, due: 53), plan: "Plus")
        }

        var claude: ProviderRateLimit {
            var claude = snapshot(.claudeCode, window(36, 5, due: 16), window(31, 168, due: 39), plan: "Max")
            claude.modelScopedMeters = [fable(58, due: 39)]
            return claude
        }

        var claudeNormal: ProviderRateLimit {
            snapshot(.claudeCode, window(36, 5, due: 16), window(53, 168, due: 39), plan: "Max")
        }

        var design: [ProviderRateLimit] {
            var cursor = ProviderRateLimit(provider: .cursor, meters: [
                .init(id: "plan", label: "Month", window: window(41, 720, due: 42)),
            ], status: .ok, fetchedAt: now)
            cursor.planLabel = "Pro"
            cursor.source = .live
            var opencode = ProviderRateLimit(provider: .opencodeGo, meters: [
                .init(id: "rolling", label: "5h", window: window(64, 5, due: 16)),
                .init(id: "weekly", label: "Weekly", window: window(48, 168, due: 42)),
                .init(id: "monthly", label: "Monthly", window: .init(utilization: 78)),
            ], status: .ok, fetchedAt: now)
            opencode.source = .live
            return [
                codex,
                claude,
                cursor,
                snapshot(.grok, nil, window(88, 168, due: 71)),
                snapshot(.antigravity, window(9, 5, due: 22), window(70, 168, due: 62)),
                snapshot(.kimiCode, window(71, 5, due: 34), window(40, 168, due: 52)),
                opencode,
                snapshot(.zCode, nil, window(72, 168, due: 67)),
            ]
        }
    }
}
