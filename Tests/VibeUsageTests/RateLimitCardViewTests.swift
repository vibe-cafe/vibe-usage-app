import Foundation
import Testing
@testable import VibeUsage

@MainActor
struct RateLimitCardViewTests {
    private func emptySnapshot(
        _ provider: ProviderRateLimit.Provider,
        reason: ProviderRateLimit.EmptyReason? = nil
    ) -> ProviderRateLimit {
        ProviderRateLimit(provider: provider, status: .noData, fetchedAt: Date(), emptyReason: reason)
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
            RateLimitCardView.emptyStateText(
                for: emptySnapshot(.claudeCode, reason: .nonessentialTrafficDisabled),
                isDetected: true
            ),
            RateLimitCardView.emptyStateText(for: emptySnapshot(.claudeCode), isDetected: true),
            RateLimitCardView.emptyStateText(for: emptySnapshot(.claudeCode), isDetected: false),
        ]

        #expect(messages == ["额度已用满 · 等待重置", "没有生效的额度窗口", "未订阅 OpenCode Go",
                             "当前登录方式不含订阅额度", "组织策略关闭了 Claude Code 非必要流量 · 无法读取",
                             "没读到额度，原因未知", "未检测到安装"])
        let placeholder = ProviderRateLimit(provider: .grok, status: .noData, fetchedAt: nil)
        #expect(RateLimitCardView.emptyStateText(for: placeholder, isDetected: true) == "尚未读取")
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
            "未找到 Claude Code", "启动失败", "读取超时",
            "没有响应", "没有返回额度",
        ])
        #expect(texts.allSatisfy { $0.detail == "来源：实时读取" })

        // An adapter that cannot name a reason keeps the generic headline.
        let generic = RateLimitCardView.retryableErrorText(
            for: ProviderRateLimit(provider: .kimiCode, status: .retryableError))
        #expect(generic.title == "暂时读不到额度")
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
            == "来源：缓存 · 读取超时")
        #expect(RateLimitCardView.staleDataNote(for: ok(.desktopRecord, .claudeBinaryNotFound))
            == "来源：Claude 桌面端记录 · 未找到 Claude Code")
        #expect(RateLimitCardView.staleDataNote(for: ok(.live, .claudeLaunchFailed))
            == "来源：上次实时读取 · 启动失败")
        #expect(RateLimitCardView.staleDataNote(for: ok(.localLog, .endpointHTTPStatus(502), provider: .codex))
            == "来源：本地日志 · 接口报错 502")
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
        #expect(RateLimitCardView.emptyStateText(for: noBinary, isDetected: true) == "未找到 Claude Code")
        #expect(RateLimitCardView.emptyStateText(for: noBinary, isDetected: false) == "未找到 Claude Code")

        let notLoggedIn = ProviderRateLimit(provider: .codex, status: .noData,
                                            liveFailure: .credentialsNotFound)
        #expect(RateLimitCardView.emptyStateText(for: notLoggedIn, isDetected: true) == "未找到登录信息")

        // OpenCode Go has no login of its own: the card says where to log in.
        let goMissing = ProviderRateLimit(provider: .opencodeGo, status: .noData, liveFailure: .credentialsNotFound)
        #expect(RateLimitCardView.emptyStateText(for: goMissing, isDetected: true) == "在 OpenCode 里登录后自动显示")
        let goExpired = ProviderRateLimit(provider: .opencodeGo, status: .noData, liveFailure: .credentialsExpired)
        #expect(RateLimitCardView.emptyStateText(for: goExpired, isDetected: true) == "打开 OpenCode 后自动显示")

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
            .claudeNoWindows, .claudeBlockedByPolicy, .credentialsNotFound, .credentialsRejected,
            .credentialsExpired, .endpointTimedOut,
            .endpointUnreachable, .endpointHTTPStatus(503), .endpointUnrecognized,
            .cliRuntimeMissing, .cliTimedOut, .cliFailed, .cliUnrecognizedOutput,
            .cliSchemaMismatch, .cliNoResult, .cliReportedFailure,
            .egressRegionUnsupported("CN"), .egressUnconfirmed, .proxyNotDetected,
        ]
        let texts = all.map { RateLimitCardView.liveFailureText($0, provider: .codex) }
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

/// #190 review follow-ups: wording the spec keeps, and the legacy fallbacks.
@MainActor
struct RateLimitCardViewReasonTests {
    @Test
    func loginCardsKeepProductSpecificWording() {
        let codex = ProviderRateLimit(provider: .codex, status: .unauthorized, liveFailure: .credentialsRejected)
        #expect(RateLimitCardView.authorizationText(for: codex) == "登录已失效，请重新登录")
        // Shipped OpenCode wording stays as it is.
        let openCode = ProviderRateLimit(provider: .opencodeGo, status: .unauthorized, liveFailure: .credentialsRejected)
        #expect(RateLimitCardView.authorizationText(for: openCode) == "请在 OpenCode 中重新登录后重试")
    }

    @Test
    func legacyUnsupportedWithoutAReasonSaysTheReasonIsUnknown() throws {
        let envelope = try QuotaCLIBridge.decode(#"{"schemaVersion":1,"products":[{"id":"cursor","status":"unsupported","meters":[],"fetchedAt":"2026-11-25T00:00:00Z","source":"live","message":"anything"}]}"#)
        let snapshot = try #require(try QuotaCLIBridge.snapshots(from: envelope).first)
        #expect(RateLimitCardView.emptyStateText(for: snapshot, isDetected: true) == "没读到额度，原因未知")
    }

    @Test
    func anUnreadableLocalRecordIsNotCalledALiveRead() {
        let grok = ProviderRateLimit(provider: .grok, status: .retryableError, source: .localLog, liveFailure: .localRecordUnreadable)
        #expect(RateLimitCardView.retryableErrorText(for: grok) == ("读不了本机记录", "来源：本地日志"))
        let kimi = ProviderRateLimit(provider: .kimiCode, status: .retryableError, source: .live, liveFailure: .endpointTimedOut)
        #expect(RateLimitCardView.retryableErrorText(for: kimi) == ("读取超时", "来源：实时读取"))
    }
}
