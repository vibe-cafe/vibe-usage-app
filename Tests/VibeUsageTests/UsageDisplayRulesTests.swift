import Foundation
import Testing
@testable import VibeUsage

struct UsageDisplayRulesTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return calendar
    }

    private func date(_ timestamp: String) -> Date {
        try! Date.ISO8601FormatStyle().parse(timestamp)
    }

    private func bucket(_ timestamp: String, _ input: Int, cost: Double? = nil,
                        source: String = "codex", model: String = "m", host: String = "mac") -> UsageBucket {
        UsageBucket(source: source, model: model, project: "p", hostname: host, bucketStart: timestamp,
                    inputTokens: input, outputTokens: 0, cacheCreation5mTokens: nil, cacheCreation1hTokens: nil,
                    cachedInputTokens: 0, reasoningOutputTokens: 0, totalTokens: input, estimatedCost: cost)
    }

    @Test
    func todayStartsAtFirstLocalUsageAndCountsBothBucketFormats() throws {
        let json = """
        [
          {"source":"codex","model":"m","project":"p","hostname":"mac","bucketStart":"2026-11-26T17:30:00Z",
           "inputTokens":100,"cacheCreation5mTokens":7,"cacheCreation1hTokens":13,"cachedInputTokens":40,
           "outputTokens":20,"reasoningOutputTokens":5,"totalTokens":145,"estimatedCost":1.25},
          {"source":"codex","model":"m","project":"p","hostname":"mac","bucketStart":"2026-11-26T17:00:00Z",
           "inputTokens":120,"cachedInputTokens":40,"outputTokens":20,"reasoningOutputTokens":5,"totalTokens":145}
        ]
        """
        var buckets = try JSONDecoder().decode([UsageBucket].self, from: Data(json.utf8))
        buckets += [bucket("2026-11-26T15:30:00Z", 999), bucket("2026-11-26T19:00:00Z", 30, cost: 2),
                    bucket("2026-11-26T19:50:00Z", 999)]
        let result = UsageDisplaySnapshot(buckets: buckets, range: .today,
                                          now: date("2026-11-26T19:40:00Z"), calendar: calendar)
        #expect(result.series.map(\.start) == ["2026-11-26T17:00:00Z", "2026-11-26T18:00:00Z",
                                              "2026-11-26T19:00:00Z"].map(date))
        #expect(result.series.map(\.amount.totalTokens) == [370, 0, 30])
        #expect(result.series.map(\.amount.cost) == [1.25, 0, 2])
        let first = try #require(result.series.first).amount
        #expect(first.input == 240 && first.output == 50 && first.cached == 80)
        #expect(result.total.input == 270 && result.total.output == 50 && result.total.cached == 80)
        #expect(result.total.totalTokens == 400 && result.total.cost == 3.25)
        #expect(result.tokenComposition.top.map(\.name) == ["输入", "缓存", "输出"])
        #expect(result.tokenComposition.top.map(\.value) == [270, 80, 50])
        #expect(result.tokenComposition.total == 400)
        #expect(result.peakTokens == 370 && result.peakCost == 2)
        #expect(first.value(for: .cost) == 1.25)
        #expect(first.value(for: .token) == 370)
        #expect(first.value(for: .activeTime) == nil)
    }

    @Test
    func dailySeriesCrossesAMidnightDSTChangeWithoutLosingTheFollowingDay() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Santiago")!
        // Sep 6 began at 01:00. Sep 7 began at 00:00 again.
        let result = UsageDisplaySnapshot(buckets: [bucket("2026-09-06T04:00:00Z", 5),
                                                    bucket("2026-09-07T03:00:00Z", 7)],
                                          range: .sevenDays, now: date("2026-09-09T12:00:00Z"), calendar: local)
        #expect(result.series.map(\.amount.totalTokens) == [0, 0, 0, 5, 7, 0, 0])
    }

    @Test
    func clearingTheNewPanelFiltersKeepsTheClassicProjectSelection() {
        var filters = FilterState(sources: ["cursor"], models: ["Model"], projects: ["classic"], hostnames: ["mac"])
        filters.clearUsagePanelFilters()
        #expect(filters == FilterState(projects: ["classic"]))
    }

    @Test
    func ninetyLocalDaysFormTwelveFullWeeksAndOneSixDayWeek() {
        let buckets = [
            bucket("2026-08-28T16:00:00Z", 999), // Aug 29, outside the range
            bucket("2026-08-29T16:00:00Z", 1),   // Aug 30, first Sunday
            bucket("2026-09-04T16:00:00Z", 2),   // Sep 5, last day of week one
            bucket("2026-09-05T16:00:00Z", 4),   // Sep 6, first day of week two
            bucket("2026-11-21T16:00:00Z", 8),   // Nov 22, last Sunday
            bucket("2026-11-26T16:00:00Z", 16),  // Nov 27, Friday
        ]
        let now = date("2026-11-27T08:00:00Z")
        let result = UsageDisplaySnapshot(buckets: buckets, range: .ninetyDays, now: now, calendar: calendar)
        #expect(result.series.count == 13)
        #expect(result.series.map(\.amount.totalTokens) == [3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 24])
        #expect(result.series.first?.start == date("2026-08-29T16:00:00Z"))
        #expect(result.series.last?.start == date("2026-11-21T16:00:00Z"))
        #expect(result.series.last?.end == now)
        #expect(result.total.totalTokens == 31)
    }

    @Test
    func rolledUpFirstHourStillCountsInTheRollingDay() {
        // The server filters raw usage at 10:15, then labels that partial hour 10:00.
        let now = date("2026-11-27T10:15:00Z")
        let result = UsageDisplaySnapshot(buckets: [bucket("2026-11-26T10:00:00Z", 11),
                                                    bucket("2026-11-27T10:00:00Z", 3)],
                                          range: .oneDay, now: now, calendar: calendar)
        #expect(result.series.first?.start == date("2026-11-26T10:15:00Z"))
        #expect(result.series.first?.amount.totalTokens == 11)
        #expect(result.series.last?.amount.totalTokens == 3)
        #expect(result.series.last?.end == now)
        #expect(result.total.totalTokens == 14)
    }

    @Test
    func customRangeIncludesTheEntireLocalEndDay() {
        let selected = date("2026-11-18T03:00:00Z")
        let result = UsageDisplaySnapshot(buckets: [bucket("2026-11-17T15:30:00Z", 1),
                                                    bucket("2026-11-17T16:00:00Z", 2),
                                                    bucket("2026-11-18T15:30:00Z", 4),
                                                    bucket("2026-11-18T16:00:00Z", 8)],
                                          range: .custom, customDays: selected...selected,
                                          now: date("2026-11-27T00:00:00Z"), calendar: calendar)
        #expect(result.series.map(\.amount.totalTokens) == [6])
        #expect(result.series.last?.end == date("2026-11-18T16:00:00Z"))
        #expect(result.total.totalTokens == 6)
    }

    @Test
    func aSingleCustomDayIncludesTheServersFirstPartialUTCHour() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "Asia/Kathmandu")!
        let selected = date("2026-11-18T04:00:00Z")
        // Local midnight is 18:15 UTC. The first hourly API row is labelled 18:00.
        let result = UsageDisplaySnapshot(buckets: [bucket("2026-11-17T18:00:00Z", 3),
                                                    bucket("2026-11-18T18:00:00Z", 4)],
                                          range: .custom, customDays: selected...selected,
                                          now: date("2026-11-27T00:00:00Z"), calendar: local)
        #expect(result.series.map(\.amount.totalTokens) == [7])
        #expect(result.series.first?.start == date("2026-11-17T18:15:00Z"))
    }

    @Test
    func subscriptionTemporarilyReplacesOnlyTheManualToolSelection() {
        let stamp = "2026-11-27T02:00:00Z"
        let buckets = [
            bucket(stamp, 1, source: "codex", model: "alias1"),
            bucket(stamp, 2, source: "opencode", model: "alias1"),
            bucket(stamp, 4, source: "opencode", model: "alias2"),
            bucket(stamp, 8, source: "opencode", model: "other"),
            bucket(stamp, 16, source: "opencode", model: "alias2", host: "other"),
        ]
        let manual = FilterState(sources: ["codex"], models: ["Model"], projects: ["classic-only"], hostnames: ["mac"])
        var state = UsagePanelState()
        func snapshot(_ enabled: [ProviderRateLimit.Provider]) -> UsageDisplaySnapshot {
            UsageDisplaySnapshot(buckets: buckets, range: state.timeRange,
                                 filters: state.effectiveFilters(manual, enabledSubscriptions: enabled),
                                 modelName: { $0.hasPrefix("alias") ? "Model" : $0 },
                                 toolName: { $0 == "opencode" ? "OpenCode" : $0 },
                                 now: date(stamp), calendar: calendar)
        }
        let both: [ProviderRateLimit.Provider] = [.codex, .opencodeGo]
        #expect(snapshot(both).total.totalTokens == 1)
        state.selectedSubscription = .opencodeGo
        let detail = snapshot(both)
        #expect(detail.total.totalTokens == 6)
        #expect(detail.series.map(\.amount.totalTokens) == [6])
        #expect(detail.ranking(.model, by: .tokens).top.map(\.name) == ["Model"])
        #expect(detail.ranking(.tool, by: .tokens).top.map(\.name) == ["OpenCode"])
        #expect(detail.ranking(.terminal, by: .tokens).top.map(\.name) == ["mac"])
        #expect(snapshot([.opencodeGo]).total.totalTokens == 1)
        #expect(snapshot([.cursor, .codex]).total.totalTokens == 1)
        state.selectedSubscription = nil
        #expect(snapshot(both).total.totalTokens == 1)
        #expect(manual.sources == ["codex"] && manual.projects == ["classic-only"])
    }

    @Test
    func everyProductOverridesTheToolByItsUsageSource() {
        var state = UsagePanelState()
        let sources: [ProviderRateLimit.Provider: String] = [
            .codex: "codex", .claudeCode: "claude-code", .cursor: "cursor", .grok: "grok",
            .antigravity: "antigravity", .kimiCode: "kimi-code", .zCode: "zcode", .opencodeGo: "opencode",
        ]
        for (provider, source) in sources {
            state.selectedSubscription = provider
            let filters = state.effectiveFilters(FilterState(), enabledSubscriptions: ProviderRateLimit.Provider.allCases)
            #expect(filters.sources == [source])
        }
    }

    @Test
    func rankingUsesEachCardsMetricAndKeepsEveryRemainingRow() {
        let stamp = "2026-11-27T02:00:00Z"
        let buckets = [
            bucket(stamp, 50, cost: 0, model: "A"),
            bucket(stamp, 40, cost: 0, model: "B"),
            bucket(stamp, 30, cost: 3, model: "C"),
            bucket(stamp, 20, cost: 4, model: "D"),
            bucket(stamp, 15, cost: 5, model: "E"),
        ]
        let snapshot = UsageDisplaySnapshot(buckets: buckets.reversed(), range: .sevenDays,
                                            now: date(stamp), calendar: calendar)
        var state = UsagePanelState()
        #expect(state[metricFor: .model] == .tokens)
        let tokens = snapshot.ranking(.model, by: state[metricFor: .model])
        #expect(tokens.top.map(\.name) == ["A", "B", "C"])
        #expect(tokens.remainder.map(\.name) == ["D", "E"])
        #expect(tokens.remainderValue == 35 && tokens.total == 155)
        state[metricFor: .model] = .cost
        #expect(state[metricFor: .tool] == .tokens && state[metricFor: .terminal] == .tokens)
        let cost = snapshot.ranking(.model, by: state[metricFor: .model])
        #expect(cost.top.map(\.name) == ["E", "D", "C"])
        #expect(cost.top.map(\.color) == [.blue, .teal, .magenta])
        #expect(cost.remainder.map(\.name) == ["A", "B"])
        #expect(cost.remainder.map(\.color) == [.gray, .gray])
        #expect(cost.remainderValue == 0 && cost.total == 12)
        let tools = snapshot.ranking(.tool, by: state[metricFor: .tool])
        #expect(tools.top.map(\.value) == [155])
        #expect(tools.remainder.isEmpty)
    }

    @Test
    func tappingTheHeroSwitchesOnlyItsOwnDisplayUnit() {
        var state = UsagePanelState()
        #expect(state.formatCost(10.25) == "$10.25")
        #expect(state.formatTokens(12_000_000) == "12.0M")
        state.toggleHeroUnit()
        #expect(state.formatCost(10.25) == "￥71.75")
        state.hero = .token
        state.toggleHeroUnit()
        #expect(state.formatTokens(12_000_000) == "1.2千万")
        state.hero = .activeTime
        state.toggleHeroUnit()
        #expect(state.formatTokens(12_000_000) == "1.2千万")
        #expect(state.formatCost(10.25) == "￥71.75")
        state.panelDidOpen()
        state.toggleHeroUnit()
        #expect(state.formatCost(10.25) == "$10.25")
    }

    @Test
    func openingResetsOnlyTheSubscriptionHeroAndExpansion() {
        var state = UsagePanelState()
        #expect(state.timeRange == .today)
        #expect(state.hero == .cost)
        #expect(state.selectedSubscription == nil)
        #expect(!state.detailsExpanded)

        state.timeRange = .sevenDays
        state.selectedSubscription = .codex
        state.hero = .activeTime
        state.detailsExpanded = true
        state.panelDidOpen()

        #expect(state.timeRange == .sevenDays)
        #expect(state.hero == .cost)
        #expect(state.selectedSubscription == nil)
        #expect(!state.detailsExpanded)
    }
}
