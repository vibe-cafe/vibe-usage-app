import Foundation
import Testing
@testable import VibeUsage

@MainActor
struct RateLimitCardViewTests {
    private func emptySnapshot(
        _ provider: ProviderRateLimit.Provider,
        reason: ProviderRateLimit.EmptyReason? = nil
    ) -> ProviderRateLimit {
        ProviderRateLimit(provider: provider, status: .noData, emptyReason: reason)
    }

    /// "暂无数据" must say *why*, so each distinguishable reason reads
    /// differently: quota used up / no window enforced right now / nothing
    /// read yet on a detected product / product not on this Mac. A single
    /// generic line was the original bug.
    @Test
    func emptyStatesExplainEachDistinguishableReasonDifferently() {
        let messages = [
            RateLimitCardView.emptyStateText(
                for: emptySnapshot(.codex, reason: .limitReached),
                isDetected: true
            ),
            RateLimitCardView.emptyStateText(
                for: emptySnapshot(.codex, reason: .noWindow),
                isDetected: true
            ),
            RateLimitCardView.emptyStateText(
                for: emptySnapshot(.opencodeGo, reason: .notEntitled),
                isDetected: true
            ),
            RateLimitCardView.emptyStateText(
                for: emptySnapshot(.claudeCode, reason: .sessionWithoutPlanLimits),
                isDetected: true
            ),
            RateLimitCardView.emptyStateText(for: emptySnapshot(.claudeCode), isDetected: true),
            RateLimitCardView.emptyStateText(for: emptySnapshot(.claudeCode), isDetected: false),
        ]

        #expect(Set(messages).count == messages.count)
        // A missing subscription is a fact about the account, not an idle
        // window, so it names the product instead of guessing.
        #expect(messages[2] == "未订阅 OpenCode Go")
        // A Claude session without plan limits names its login method, so the
        // user is not left wondering whether the card is broken.
        #expect(messages[3] == "当前登录方式不含订阅额度（API Key / Bedrock / Vertex）")
    }

    /// The "used up" line belongs only to a source that actually reported it:
    /// a snapshot that carries no reason (session JSONL, disk cache, another
    /// provider) must not borrow it.
    @Test
    func unexplainedEmptyDoesNotClaimQuotaExhaustion() {
        let unexplained = RateLimitCardView.emptyStateText(
            for: emptySnapshot(.codex),
            isDetected: true
        )
        let exhausted = RateLimitCardView.emptyStateText(
            for: emptySnapshot(.codex, reason: .limitReached),
            isDetected: true
        )

        #expect(unexplained != exhausted)
    }

    // MARK: - Live failure reasons (diagnostics 1a)

    /// The 11-09 class of report: a retryable Claude card used to read the
    /// same generic line for every failure. Each reason now reads differently,
    /// and the card states that it tried a live read.
    @Test
    func retryableClaudeCardsNameTheirFixedReason() {
        let reasons: [ProviderRateLimit.LiveFailure] = [
            .claudeBinaryNotFound, .claudeLaunchFailed, .claudeTimedOut,
            .claudeNoResponse, .claudeNoWindows,
        ]
        let texts = reasons.map {
            RateLimitCardView.retryableErrorText(for: ProviderRateLimit(
                provider: .claudeCode, status: .retryableError, liveFailure: $0))
        }

        #expect(Set(texts.map(\.title)).count == reasons.count)
        #expect(texts.map(\.title) == [
            "未找到 Claude Code 程序", "Claude 启动失败", "Claude 配额读取超时",
            "Claude 没有响应配额请求", "Claude 没有返回额度窗口",
        ])
        #expect(texts.allSatisfy { $0.detail == "来源：实时读取" })

        // An adapter that cannot name a reason keeps the generic headline.
        let generic = RateLimitCardView.retryableErrorText(
            for: ProviderRateLimit(provider: .kimiCode, status: .retryableError))
        #expect(generic.title == "暂时无法读取订阅配额")
        #expect(generic.detail == "来源：实时读取")
    }

    /// Cached numbers stay on screen after a failed live read; the card adds
    /// one line naming the source and the reason. A successful live card adds
    /// nothing (an age line under every card was removed as noise).
    @Test
    func cachedReadingAfterFailedLiveReadNamesSourceAndReason() {
        func ok(_ source: ProviderRateLimit.Source?, _ failure: ProviderRateLimit.LiveFailure?,
                provider: ProviderRateLimit.Provider = .claudeCode) -> ProviderRateLimit {
            ProviderRateLimit(
                provider: provider,
                fiveHour: RateLimitWindow(utilization: 10),
                status: .ok,
                source: source,
                liveFailure: failure
            )
        }

        #expect(RateLimitCardView.staleDataNote(for: ok(.cache, .claudeTimedOut))
            == "来源：缓存 · Claude 配额读取超时")
        #expect(RateLimitCardView.staleDataNote(for: ok(.desktopRecord, .claudeBinaryNotFound))
            == "来源：Claude 桌面端记录 · 未找到 Claude Code 程序")
        #expect(RateLimitCardView.staleDataNote(for: ok(.live, .claudeLaunchFailed))
            == "来源：上次实时读取 · Claude 启动失败")
        #expect(RateLimitCardView.staleDataNote(for: ok(.localLog, .endpointHTTPStatus(502), provider: .codex))
            == "来源：本地日志 · Codex 配额接口返回错误 502")
        #expect(RateLimitCardView.staleDataNote(for: ok(.cache, .cliReportedFailure, provider: .kimiCode))
            == "来源：缓存 · 实时读取失败")

        #expect(RateLimitCardView.staleDataNote(for: ok(.live, nil)) == nil)
        #expect(RateLimitCardView.staleDataNote(for: ok(.cache, nil)) == nil)
        #expect(RateLimitCardView.staleDataNote(for: ProviderRateLimit(
            provider: .claudeCode, status: .retryableError, liveFailure: .claudeTimedOut)) == nil)
    }

    /// A settled empty card prefers the source's own answer, then the live
    /// read's reason, then local detection.
    @Test
    func emptyCardPrefersTheLiveReadReasonOverDetection() {
        let noBinary = ProviderRateLimit(provider: .claudeCode, status: .noData,
                                         liveFailure: .claudeBinaryNotFound)
        #expect(RateLimitCardView.emptyStateText(for: noBinary, isDetected: true) == "未找到 Claude Code 程序")
        #expect(RateLimitCardView.emptyStateText(for: noBinary, isDetected: false) == "未找到 Claude Code 程序")

        let notLoggedIn = ProviderRateLimit(provider: .codex, status: .noData,
                                            liveFailure: .credentialsNotFound)
        #expect(RateLimitCardView.emptyStateText(for: notLoggedIn, isDetected: true) == "未找到 Codex 登录信息")

        let answered = ProviderRateLimit(provider: .opencodeGo, status: .noData,
                                         emptyReason: .notEntitled, liveFailure: .credentialsNotFound)
        #expect(RateLimitCardView.emptyStateText(for: answered, isDetected: true) == "未订阅 OpenCode Go")
    }

    /// Every reason is our own copy: no path, key, or server text can appear,
    /// only the product name and an HTTP status number.
    @Test
    func failureCopyIsFixedText() {
        let all: [ProviderRateLimit.LiveFailure] = [
            .claudeBinaryNotFound, .claudeLaunchFailed, .claudeTimedOut, .claudeNoResponse,
            .claudeNoWindows, .credentialsNotFound, .credentialsRejected, .endpointTimedOut,
            .endpointUnreachable, .endpointHTTPStatus(503), .endpointUnrecognized,
            .cliRuntimeMissing, .cliTimedOut, .cliFailed, .cliUnrecognizedOutput,
            .cliSchemaMismatch, .cliNoResult, .cliReportedFailure,
        ]
        let texts = all.map { RateLimitCardView.liveFailureText($0, provider: .codex) }
        #expect(Set(texts).count == all.count)
        #expect(texts.allSatisfy { !$0.contains("/") && !$0.contains("~") })
    }

    @Test
    func genericQuotaWindowsLeadFromShortestToLongest() {
        let meters = [
            RateLimitMeter(id: "mcp", label: "MCP", window: RateLimitWindow(utilization: 4, windowDuration: 30 * 86_400)),
            RateLimitMeter(id: "weekly", label: "Weekly", window: RateLimitWindow(utilization: 30)),
            RateLimitMeter(id: "sonnet", label: "Sonnet", window: RateLimitWindow(utilization: 40, windowDuration: 7 * 86_400)),
            RateLimitMeter(id: "five-hour", label: "5h", window: RateLimitWindow(utilization: 10, windowDuration: 5 * 3_600)),
            RateLimitMeter(id: "extra", label: "额外", window: RateLimitWindow(utilization: 50)),
        ]

        let ordered = QuotaMeterLayout.canonicalMeters(meters)

        #expect(ordered.map(\.label) == ["5h", "7d", "MCP", "Sonnet", "额外"])
        #expect(ordered[1].window.windowDuration == TimeInterval(7 * 86_400))
    }

    /// A lone enabled product fills the row. Its 240pt column leaves half the
    /// popover empty, which the user reported reading as a layout error: they
    /// turned the other products off, so nothing is being made room for. Two
    /// cards already fill the row exactly, and widening beyond that would only
    /// push a card off-screen.
    @Test
    func aLoneCardFillsTheRowWhileTwoOrMoreKeepTheirColumn() {
        #expect(RateLimitCardView.width(forProviderCount: 1) == RateLimitCardView.loneCardWidth)
        #expect(RateLimitCardView.width(forProviderCount: 2) == RateLimitCardView.cardWidth)
        #expect(RateLimitCardView.width(forProviderCount: 5) == RateLimitCardView.cardWidth)
        // The lone width is the popover's whole content box — 520 minus 2×16
        // side padding minus the 8pt gap — so the card ends flush with the
        // sections below it. Pinned literally because the arithmetic lives in a
        // comment: a padding or card-width change that is not mirrored here
        // would put the card back to a half-empty row.
        #expect(RateLimitCardView.loneCardWidth == 488)
    }

    /// The card's scroll target must not collide with the tab strip's identity.
    ///
    /// Both used to carry the provider itself (`ForEach(..., id: \.self)` on
    /// each side), so `scrollTo(provider)` could resolve to the tab — which sits
    /// outside the horizontal scroller and is already on screen — and a click on
    /// an enabled tab moved the card row nowhere. Pinned so the two identities
    /// cannot silently converge again.
    @Test
    func cardScrollTargetsAreNamespacedAndUnique() {
        let providers = ProviderRateLimit.Provider.allCases
        #expect(Set(providers.map(RateLimitCardView.cardID)).count == providers.count)
        for provider in providers {
            #expect(RateLimitCardView.cardID(provider) != provider.rawValue)
        }
        #expect(RateLimitCardView.cardID(.codex) == "quota-card-codex")
    }
}
