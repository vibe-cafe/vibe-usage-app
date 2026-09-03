import Foundation
import Testing
@testable import VibeUsage

@MainActor
struct RateLimitCardViewTests {
    private func snapshot(
        provider: ProviderRateLimit.Provider,
        status: ProviderRateLimit.Status
    ) -> ProviderRateLimit {
        ProviderRateLimit(provider: provider, status: status)
    }

    /// Regression for the Settings mismatch: Claude is enabled, but its
    /// settled `.noData` result used to make the card disappear whenever Codex
    /// had data, leaving the dashboard looking Codex-only.
    @Test
    func enabledClaudeRemainsVisibleBesideAvailableCodex() {
        let visible = RateLimitCardView.visibleProviders(
            codex: snapshot(provider: .codex, status: .ok),
            claude: snapshot(provider: .claudeCode, status: .noData),
            codexEnabled: true,
            claudeEnabled: true,
            codexRefreshing: false,
            claudeRefreshing: false
        )

        #expect(visible == [.codex, .claudeCode])
    }

    /// Preserve the intentionally compact empty state when neither provider
    /// has anything useful to show.
    @Test
    func twoSettledEmptyProvidersUseTheNoticeBar() {
        let visible = RateLimitCardView.visibleProviders(
            codex: snapshot(provider: .codex, status: .noData),
            claude: snapshot(provider: .claudeCode, status: .noData),
            codexEnabled: true,
            claudeEnabled: true,
            codexRefreshing: false,
            claudeRefreshing: false
        )

        #expect(visible.isEmpty)
    }

    @Test
    func onlyEnabledProviderIsVisible() {
        let visible = RateLimitCardView.visibleProviders(
            codex: snapshot(provider: .codex, status: .ok),
            claude: snapshot(provider: .claudeCode, status: .ok),
            codexEnabled: false,
            claudeEnabled: true,
            codexRefreshing: false,
            claudeRefreshing: false
        )

        #expect(visible == [.claudeCode])
    }

    @Test
    func refreshingClaudeKeepsBothEnabledProvidersVisible() {
        let visible = RateLimitCardView.visibleProviders(
            codex: snapshot(provider: .codex, status: .noData),
            claude: snapshot(provider: .claudeCode, status: .noData),
            codexEnabled: true,
            claudeEnabled: true,
            codexRefreshing: false,
            claudeRefreshing: true
        )

        #expect(visible == [.codex, .claudeCode])
    }

    @Test
    func disabledRefreshingProviderIsNotVisible() {
        let visible = RateLimitCardView.visibleProviders(
            codex: snapshot(provider: .codex, status: .ok),
            claude: snapshot(provider: .claudeCode, status: .noData),
            codexEnabled: true,
            claudeEnabled: false,
            codexRefreshing: false,
            claudeRefreshing: true
        )

        #expect(visible == [.codex])
    }

    @Test
    func enabledGrokRemainsVisibleBesideAvailableCodex() {
        let visible = RateLimitCardView.visibleProviders(
            codex: snapshot(provider: .codex, status: .ok),
            claude: snapshot(provider: .claudeCode, status: .noData),
            grok: snapshot(provider: .grok, status: .noData),
            codexEnabled: true,
            claudeEnabled: false,
            grokEnabled: true,
            codexRefreshing: false,
            claudeRefreshing: false,
            grokRefreshing: false
        )

        #expect(visible == [.codex, .grok])
    }

    @Test
    func threeSettledEmptyProvidersUseTheNoticeBar() {
        let visible = RateLimitCardView.visibleProviders(
            codex: snapshot(provider: .codex, status: .noData),
            claude: snapshot(provider: .claudeCode, status: .noData),
            grok: snapshot(provider: .grok, status: .noData),
            codexEnabled: true,
            claudeEnabled: true,
            grokEnabled: true,
            codexRefreshing: false,
            claudeRefreshing: false,
            grokRefreshing: false
        )

        #expect(visible.isEmpty)
    }

    @Test
    func grokWeeklyWindowKeepsSevenDayLabel() {
        let snapshot = ProviderRateLimit(
            provider: .grok,
            sevenDay: RateLimitWindow(utilization: 9, windowDuration: 7 * 86_400),
            status: .ok
        )
        #expect(RateLimitCardView.longWindowLabel(for: snapshot, window: snapshot.sevenDay!) == "7d")
    }
}
