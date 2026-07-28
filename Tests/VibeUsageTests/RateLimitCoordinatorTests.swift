import Foundation
import Testing
@testable import VibeUsage

struct RateLimitCoordinatorTests {
    private func snapshot(
        utilization: Double,
        dataAsOf: Date?,
        fetchedAt: Date? = nil,
        status: ProviderRateLimit.Status = .ok
    ) -> ProviderRateLimit {
        ProviderRateLimit(
            provider: .codex,
            sevenDay: RateLimitWindow(utilization: utilization),
            status: status,
            fetchedAt: fetchedAt,
            dataAsOf: dataAsOf
        )
    }

    @Test
    func newerFallbackMayReplaceCurrentSnapshot() {
        let current = snapshot(
            utilization: 40,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )
        let fallback = snapshot(
            utilization: 50,
            dataAsOf: Date(timeIntervalSince1970: 200)
        )

        #expect(RateLimitCoordinator.isNewerSnapshot(fallback, than: current))
    }

    @Test
    func olderFallbackCannotMakeDisplayedDataGoBackwards() {
        let current = snapshot(
            utilization: 50,
            dataAsOf: Date(timeIntervalSince1970: 200)
        )
        let fallback = snapshot(
            utilization: 40,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )

        #expect(!RateLimitCoordinator.isNewerSnapshot(fallback, than: current))
    }

    @Test
    func fetchedAtIsUsedOnlyWhenDataAsOfIsUnavailable() {
        let current = snapshot(
            utilization: 40,
            dataAsOf: nil,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let fallback = snapshot(
            utilization: 50,
            dataAsOf: nil,
            fetchedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(RateLimitCoordinator.isNewerSnapshot(fallback, than: current))
    }

    @Test
    func nonOkFallbackNeverReplacesCurrentData() {
        let fallback = snapshot(
            utilization: 0,
            dataAsOf: Date(timeIntervalSince1970: 200),
            status: .noData
        )

        #expect(!RateLimitCoordinator.isNewerSnapshot(fallback, than: nil))
    }

    @Test @MainActor
    func concurrentCodexRefreshesShareOneLiveRequest() async {
        let appState = AppState()
        var fetchCount = 0
        let producedAt = Date(timeIntervalSince1970: 200)
        let live = snapshot(utilization: 50, dataAsOf: producedAt)
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: {
                fetchCount += 1
                try await Task.sleep(for: .milliseconds(50))
                return live
            },
            loadCodexCache: { nil },
            readCodexFallback: {
                ProviderRateLimit(provider: .codex, status: .noData)
            }
        )

        let first = Task { @MainActor in await coordinator.refreshCodex() }
        let second = Task { @MainActor in await coordinator.refreshCodex() }
        await first.value
        await second.value

        #expect(fetchCount == 1)
        #expect(appState.rateLimits.first(where: { $0.provider == .codex }) == live)
        #expect(!appState.isCodexRateLimitRefreshing)
    }

    @Test @MainActor
    func closingPanelCancelsCodexRefreshWithoutPublishingLateData() async {
        let appState = AppState()
        var requestStarted = false
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: {
                requestStarted = true
                try await Task.sleep(for: .seconds(30))
                return self.snapshot(
                    utilization: 99,
                    dataAsOf: Date(timeIntervalSince1970: 300)
                )
            },
            loadCodexCache: { nil },
            readCodexFallback: {
                ProviderRateLimit(provider: .codex, status: .noData)
            }
        )

        let refresh = Task { @MainActor in await coordinator.refreshCodex() }
        while !requestStarted { await Task.yield() }
        #expect(appState.isCodexRateLimitRefreshing)

        coordinator.panelVisibilityChanged(visible: false)
        await refresh.value

        #expect(!appState.isCodexRateLimitRefreshing)
        #expect(appState.rateLimits.first(where: { $0.provider == .codex }) == nil)
    }

    private func claudeSnapshot(
        utilization: Double,
        dataAsOf: Date?
    ) -> ProviderRateLimit {
        ProviderRateLimit(
            provider: .claudeCode,
            fiveHour: RateLimitWindow(utilization: utilization),
            status: .ok,
            fetchedAt: dataAsOf,
            dataAsOf: dataAsOf
        )
    }

    /// The cold-open contract: the on-disk cache paints first so the card is
    /// never blank during the probe's ~2.5s round trip, then the live reading
    /// replaces it.
    @Test @MainActor
    func claudeCachePaintsBeforeLiveProbeReplacesIt() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        var paintedWhileProbing: ProviderRateLimit?

        let cached = claudeSnapshot(
            utilization: 10,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )
        let live = claudeSnapshot(
            utilization: 42,
            dataAsOf: Date(timeIntervalSince1970: 200)
        )

        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: {
                paintedWhileProbing = appState.rateLimits.first { $0.provider == .claudeCode }
                return live
            },
            loadClaudeCache: { cached }
        )

        await coordinator.refreshClaude()

        #expect(paintedWhileProbing == cached)
        #expect(appState.rateLimits.first { $0.provider == .claudeCode } == live)
        #expect(!appState.isClaudeRateLimitRefreshing)
    }

    /// A failing probe must not blank a card the cache already filled — the
    /// 「数据截至」 footer states the age honestly instead.
    @Test @MainActor
    func claudeProbeFailureKeepsCachedSnapshot() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        let cached = claudeSnapshot(
            utilization: 10,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )

        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: { throw ClaudeUsageProbe.ProbeError.noBinary },
            loadClaudeCache: { cached }
        )

        await coordinator.refreshClaude()

        #expect(appState.rateLimits.first { $0.provider == .claudeCode } == cached)
    }

    /// An API-key / Bedrock session has no plan quota at all. That is a
    /// permanent answer, so the card collapses rather than showing stale
    /// percentages or implying a retry would help.
    @Test @MainActor
    func claudeAccountWithoutPlanLimitsCollapsesTheCard() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: { throw ClaudeUsageProbe.ProbeError.limitsNotApplicable },
            loadClaudeCache: {
                self.claudeSnapshot(
                    utilization: 10,
                    dataAsOf: Date(timeIntervalSince1970: 100)
                )
            }
        )

        await coordinator.refreshClaude()

        #expect(appState.rateLimits.first { $0.provider == .claudeCode }?.status == .noData)
    }
}
