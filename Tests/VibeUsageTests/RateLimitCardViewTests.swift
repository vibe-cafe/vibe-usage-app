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

    /// Every enabled product owns a card, in selection order, whatever its
    /// state. Four products is where the old two-slot layout used to drop rows
    /// and where the section used to fold into one capability notice; the row
    /// now scrolls instead.
    @Test
    func everyEnabledProductGetsItsOwnCardInSelectionOrder() {
        let content = RateLimitCardView.sectionContent(
            selected: [.codex, .claudeCode, .kimiCode, .grok]
        )

        #expect(content == .cards([.codex, .claudeCode, .kimiCode, .grok]))
    }

    /// The notice is reserved for "you enabled nothing", where it explains the
    /// selector beside it. It must never stand in for a card — including a
    /// single empty one.
    @Test
    func noticeIsReservedForAnEmptySelection() {
        #expect(RateLimitCardView.sectionContent(selected: []) == .notice)
        #expect(RateLimitCardView.sectionContent(selected: [.cursor]) == .cards([.cursor]))
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
            RateLimitCardView.emptyStateText(for: emptySnapshot(.claudeCode), isDetected: true),
            RateLimitCardView.emptyStateText(for: emptySnapshot(.claudeCode), isDetected: false),
        ]

        #expect(Set(messages).count == messages.count)
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
}
