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
            RateLimitCardView.emptyStateText(
                for: emptySnapshot(.opencode, reason: .notEntitled),
                isDetected: true
            ),
            RateLimitCardView.emptyStateText(for: emptySnapshot(.claudeCode), isDetected: true),
            RateLimitCardView.emptyStateText(for: emptySnapshot(.claudeCode), isDetected: false),
        ]

        #expect(Set(messages).count == messages.count)
        // A missing subscription is a fact about the account, not an idle
        // window, so it names the product instead of guessing.
        #expect(messages[2] == "未订阅 OpenCode Go")
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
}
