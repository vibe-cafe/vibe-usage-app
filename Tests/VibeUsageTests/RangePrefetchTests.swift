import Foundation
import Testing
@testable import VibeUsage

@MainActor
struct RangePrefetchTests {
    @MainActor private final class Fixture {
        let domain = "RangePrefetch.\(UUID().uuidString)"
        var config = VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test")
        var now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        var usage: [UsageQueryRange] = []
        var activity: [UsageQueryRange] = []
        var beforeUsage: (UsageQueryRange) async throws -> Void = { _ in }
        var beforeActivity: (UsageQueryRange) async -> Void = { _ in }

        func state(_ style: InterfaceStyle = .modern) -> AppState {
            let preference = InterfaceStylePreference(domain: domain, rollout: .externalTest)
            preference.select(style)
            let state = AppState(
                initialConfig: config, loadConfig: { self.config },
                usageFetcher: { _, _, range in
                    self.usage.append(range)
                    try await self.beforeUsage(range)
                    let cost = Double(self.usage.filter { $0 == range }.count)
                    let row = UsageBucket(source: "codex", model: range.queryItems[0].value!, project: "p", hostname: "mac",
                                          bucketStart: self.now.formatted(.iso8601), inputTokens: 1, outputTokens: 0,
                                          cacheCreation5mTokens: nil, cacheCreation1hTokens: nil, cachedInputTokens: 0,
                                          reasoningOutputTokens: 0, totalTokens: 1, estimatedCost: cost)
                    return UsageResponse(buckets: [row], sessions: nil, hasAnyData: true, names: nil)
                },
                activityFetcher: { _, _, range, filters, _ in
                    self.activity.append(range)
                    await self.beforeActivity(range)
                    let seconds = filters.hostnames.isEmpty ? self.activity.filter { $0 == range }.count : 10
                    return UsageActivity(activeSeconds: seconds, workSeconds: seconds, parallel: 1, series: [],
                                         firstBucketStart: "2020-01-01T00:00:00Z")
                },
                quotaDefaults: UserDefaults(suiteName: domain)!, interfaceStyle: preference
            )
            state.usageNow = { self.now }
            state.applyDefaultTimeRangeForInterfaceStyle()
            return state
        }

        func clean() { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
    }

    @Test func openWaitsForBothCurrentReadsAndDebouncesReopens() async throws {
        let f = Fixture()
        defer { f.clean() }
        let state = f.state()
        let today = state.currentQueryRange
        var finishActivity: CheckedContinuation<Void, Never>?
        f.beforeActivity = { range in
            if range == today { await withCheckedContinuation { finishActivity = $0 } }
        }
        let opened = state.panelWillOpen()
        try await waitForDashboard { state.hasLoadedUsageData && finishActivity != nil }
        #expect(f.usage == [today] && f.activity == [today])
        f.beforeActivity = { _ in }
        finishActivity?.resume()
        await opened.value
        try await waitForDashboard { f.usage.count == 5 && f.activity.count == 5 }
        for range in [today, .days(1), .days(7), .days(30), .days(90)] {
            #expect(f.usage.filter { $0 == range }.count == 1)
            #expect(f.activity.filter { $0 == range }.count == 1)
        }
        await state.panelWillOpen().value
        #expect(f.usage.count == 5 && f.activity.count == 5)
    }

    @Test func classicOpensAndRangeChangesKeepTheirOriginalReads() async throws {
        let f = Fixture()
        defer { f.clean() }
        let state = f.state(.classic)
        await state.panelWillOpen().value
        try await waitForDashboard { state.activity != nil }
        await state.panelWillOpen().value
        #expect(f.usage == [.days(1)] && f.activity == [.days(1)])
        state.timeRange = .sevenDays
        await state.fetchUsageData()
        try await waitForDashboard { state.activity != nil }
        var finish: CheckedContinuation<Void, Never>?
        f.beforeUsage = { _ in await withCheckedContinuation { finish = $0 } }
        state.timeRange = .oneDay
        let revisit = Task { await state.fetchUsageData() }
        try await waitForDashboard { finish != nil }
        #expect(state.isRefreshingData && state.buckets.first?.model == "7")
        finish?.resume()
        await revisit.value
        try await waitForDashboard { state.activity != nil }
        #expect(f.usage == [.days(1), .days(7), .days(1)])
        #expect(f.activity == f.usage)
    }

    @Test func switchingToClassicKeepsAnIdenticalPendingRead() async throws {
        let f = Fixture()
        defer { f.clean() }
        let state = f.state()
        var release: CheckedContinuation<Void, Never>?
        f.beforeUsage = { _ in await withCheckedContinuation { release = $0 } }
        state.selectUsagePeriod(.oneDay)
        try await waitForDashboard { release != nil && state.activity != nil }
        state.selectInterfaceStyle(.classic)
        await state.panelWillOpen().value
        #expect(state.isLoadingData && f.usage == [.days(1)] && f.activity == f.usage)
        release?.resume()
        try await waitForDashboard { !state.isLoadingData && !state.buckets.isEmpty }
    }

    @Test func switchesShowBothCachedResultsWhileOnlyStaleReadsRefresh() async throws {
        let f = Fixture()
        defer { f.clean() }
        let state = f.state()
        await state.panelWillOpen().value
        let keeper = UsageFiguresKeeper()
        func checkFigures(_ cost: Double, seconds: Int) {
            guard case .figures(let snapshot, faded: false) = keeper.figures(state, filters: .init(), now: f.now) else {
                Issue.record("Expected the selected range in full brightness")
                return
            }
            #expect(snapshot.total.cost == cost && state.activity?.summary?.activeSeconds == seconds)
            #expect(!state.isLoadingData && !state.isLoadingActivity && !state.isUsageReadPending)
        }
        for period in UsageFilterSummary.quickPeriods {
            state.selectUsagePeriod(period)
            checkFigures(1, seconds: 1)
            #expect(state.buckets.first?.model == state.currentQueryRange.queryItems[0].value)
        }
        #expect(f.usage.count == 5 && f.activity.count == 5)
        f.now.addTimeInterval(61)
        var release: CheckedContinuation<Void, Never>?
        f.beforeUsage = { _ in await withCheckedContinuation { release = $0 } }
        state.selectUsagePeriod(.sevenDays)
        checkFigures(1, seconds: 1)
        try await waitForDashboard { release != nil && state.activity?.summary?.activeSeconds == 2 }
        state.selectUsagePeriod(.sevenDays)
        checkFigures(1, seconds: 2)
        release?.resume()
        try await waitForDashboard { state.buckets.first?.estimatedCost == 2 }
        checkFigures(2, seconds: 2)
        #expect(f.usage.count == 6 && f.activity.count == 6)
        f.beforeUsage = { _ in }
        await state.panelWillOpen().value
        #expect(f.usage.count == 6 && f.activity.count == 6)
        f.now.addTimeInterval(240)
        await state.panelWillOpen().value
        #expect(f.usage.count == 11 && f.activity.count == 11)
    }

    @Test func activityUsesItsEffectiveFiltersAndASelectedPrefetchIsShared() async throws {
        let f = Fixture()
        defer { f.clean() }
        let state = f.state()
        var release: CheckedContinuation<Void, Never>?
        f.beforeUsage = { range in
            if range == .days(30) { await withCheckedContinuation { release = $0 } }
        }
        let open = state.panelWillOpen()
        try await waitForDashboard { release != nil }
        state.selectUsagePeriod(.thirtyDays)
        #expect(state.isLoadingData)
        release?.resume()
        await open.value
        #expect(f.usage.count == 5 && state.buckets.first?.estimatedCost == 1)
        state.filters.hostnames = ["mac"]
        #expect(state.activity == nil)
        try await waitForDashboard { state.activity?.summary?.activeSeconds == 10 }
        state.selectUsagePeriod(.sevenDays)
        #expect(!state.isLoadingData && state.activity == nil)
        try await waitForDashboard { state.activity?.summary?.activeSeconds == 10 }
        state.filters.hostnames = []
        #expect(state.activity?.summary?.activeSeconds == 1)
        #expect(f.usage.count == 5 && f.activity.count == 7)
    }

    @Test func aFailedPrefetchHasNoFiguresAndAFailedRefreshKeepsItsSuccess() async throws {
        let f = Fixture()
        defer { f.clean() }
        let state = f.state()
        let keeper = UsageFiguresKeeper()
        var fail = true
        f.beforeUsage = { range in
            if range == .days(7) && fail { throw URLError(.timedOut) }
        }
        await state.panelWillOpen().value
        _ = keeper.figures(state, filters: .init(), now: f.now)
        state.selectUsagePeriod(.sevenDays)
        if case .figures(_, faded: true) = keeper.figures(state, filters: .init(), now: f.now) {
            #expect(state.isLoadingData)
        } else { Issue.record("Expected faded figures until the read ends") }
        try await waitForDashboard { !state.isLoadingData }
        if case .unavailable = keeper.figures(state, filters: .init(), now: f.now) {
            #expect(state.activity != nil)
        } else { Issue.record("Expected unavailable usage with separately readable activity") }
        fail = false
        state.selectUsagePeriod(.sevenDays)
        try await waitForDashboard { !state.isLoadingData }
        let cost = try #require(state.buckets.first?.estimatedCost)
        fail = true
        f.now.addTimeInterval(61)
        let before = state.usageReadsFinished
        state.selectUsagePeriod(.sevenDays)
        #expect(!state.isLoadingData)
        try await waitForDashboard { state.usageReadsFinished != before }
        guard case .figures(let snapshot, faded: false) = keeper.figures(state, filters: .init(), now: f.now) else {
            Issue.record("A failed background refresh hid the last success")
            return
        }
        #expect(snapshot.total.cost == cost)
    }

    @Test func launchAndScheduledSyncReadOnlyTheCurrentRange() async throws {
        let f = Fixture()
        defer { f.clean() }
        let state = f.state()
        state.saveConfig = { f.config = $0 }
        // configure starts the scheduler and its eager dashboard fetch. Keep
        // the launch upload separate from the subsequent successful timer tick.
        state.runSync = { (.failure(.timeout), nil) }
        state.configure(apiKey: "fixture", server: UsageServer(f.config.apiUrl))
        try await waitForDashboard {
            if case .error = state.syncStatus { return state.activity != nil && state.hasLoadedUsageData }
            return false
        }
        #expect(f.usage == [state.currentQueryRange] && f.activity == f.usage)
        state.runSync = { (.success("ok"), nil) }
        await state.triggerSync(.scheduled)
        #expect(f.usage == [state.currentQueryRange, state.currentQueryRange] && f.activity == f.usage)
    }

    @Test func openingOnCustomDatesRespectsTheEightExtraRequestLimit() async {
        let f = Fixture()
        defer { f.clean() }
        let state = f.state()
        state.timeRange = .custom
        await state.panelWillOpen().value
        #expect(f.usage.first == state.currentQueryRange && f.activity.first == state.currentQueryRange)
        #expect(f.usage.count == 5 && f.activity.count == 5)
        f.now.addTimeInterval(61)
        await state.panelWillOpen().value
        #expect(f.usage.count == 7 && f.activity.count == 7)
        #expect(f.usage.contains(.days(90)) && f.activity.contains(.days(90)))
    }

    @Test func aRangeSelectedDuringOpeningAlsoFinishesBeforePrefetch() async throws {
        let f = Fixture()
        defer { f.clean() }
        let state = f.state()
        let today = state.currentQueryRange
        var finishToday: CheckedContinuation<Void, Never>?
        var finishWeek: CheckedContinuation<Void, Never>?
        f.beforeActivity = { range in
            if range == today { await withCheckedContinuation { finishToday = $0 } }
            if range == .days(7) { await withCheckedContinuation { finishWeek = $0 } }
        }
        let open = state.panelWillOpen()
        try await waitForDashboard { finishToday != nil && state.hasLoadedUsageData }
        state.selectUsagePeriod(.sevenDays)
        try await waitForDashboard { finishWeek != nil && !state.isLoadingData }
        finishToday?.resume()
        try await Task.sleep(for: .milliseconds(25))
        #expect(f.usage == [today, .days(7)] && f.activity == f.usage)
        finishWeek?.resume()
        await open.value
        #expect(f.usage.count == 5 && f.activity.count == 5)
    }

    @Test func midnightExpiresBothHourlyPeriodsEvenInsideTheDebounce() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-2)
        let state = f.state()
        await state.panelWillOpen().value
        state.selectUsagePeriod(.oneDay)
        let keeper = UsageFiguresKeeper()
        _ = keeper.figures(state, filters: .init(), now: f.now)
        f.now.addTimeInterval(4)
        #expect(state.usageDisplaySnapshot(filters: .init(), now: f.now) == nil)
        state.selectUsagePeriod(.today)
        #expect(state.activity == nil)
        if case .figures = keeper.figures(state, filters: .init(), now: f.now) {
            Issue.record("Yesterday's figures survived midnight")
        }
        state.selectUsagePeriod(.oneDay)
        #expect(state.activity == nil && state.isLoadingData)
        #expect(state.usageDisplaySnapshot(filters: .init(), now: f.now) == nil)
        try await waitForDashboard { state.activity != nil && !state.isLoadingData }
        state.selectUsagePeriod(.sevenDays)
        #expect(!state.isLoadingData && state.activity?.summary?.activeSeconds == 1)
        #expect(f.usage.count == 7 && f.activity.count == 7)
    }

    @Test(arguments: ["key", "server", "reset"])
    func accountChangesDiscardResultsAndLatePrefetches(change: String) async throws {
        let f = Fixture()
        defer { f.clean() }
        let state = f.state()
        var release: CheckedContinuation<Void, Never>?
        f.beforeUsage = { range in
            if range == .days(90) { await withCheckedContinuation { release = $0 } }
        }
        let open = state.panelWillOpen()
        try await waitForDashboard { release != nil }
        if change == "key" { f.config.apiKey = "another-fixture" }
        if change == "server" { f.config.apiUrl = "https://other.example.test" }
        if change == "reset" { f.config.apiKey = nil }
        state.applyConfig(change == "reset" ? nil : f.config)
        release?.resume()
        await open.value
        #expect(state.buckets.isEmpty && state.activity == nil)
        f.beforeUsage = { _ in }
        state.selectUsagePeriod(.ninetyDays)
        #expect(state.buckets.isEmpty && state.activity == nil)
        if change == "reset" {
            await state.panelWillOpen().value
            #expect(f.usage.filter { $0 == .days(90) }.count == 1)
        } else {
            try await waitForDashboard { state.buckets.first?.estimatedCost == 2 }
        }
    }
}
