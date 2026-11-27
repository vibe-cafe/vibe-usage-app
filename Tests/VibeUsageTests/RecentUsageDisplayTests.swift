import Foundation
import Testing
@testable import VibeUsage

/// What the new panel's 近期消耗 card draws from the usage rules' output:
/// the big number's pieces, the curve's points and labels, the hover
/// content, the filter chips and the activity curve. Fixed data, a fixed
/// clock and a fixed time zone.
struct RecentUsageDisplayTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return calendar
    }

    private func date(_ timestamp: String) -> Date {
        try! Date.ISO8601FormatStyle().parse(timestamp)
    }

    private func bucket(_ timestamp: String, cost: Double, tokens: Int = 1_000) -> UsageBucket {
        UsageBucket(source: "codex", model: "m", project: "p", hostname: "mac", bucketStart: timestamp,
                    inputTokens: tokens / 10, outputTokens: tokens / 10, cacheCreation5mTokens: nil,
                    cacheCreation1hTokens: nil, cachedInputTokens: tokens - 2 * (tokens / 10),
                    reasoningOutputTokens: 0, totalTokens: tokens, estimatedCost: cost)
    }

    // MARK: Big number

    @Test func bigNumberSplitsSignIntegerDecimalsAndUnits() {
        typealias Part = RecentUsageNumberPart
        #expect(RecentUsageNumber.parts("$41.20", dropsCentsFromHundred: true)
            == [Part(text: "$", role: .symbol), Part(text: "41", role: .integer), Part(text: "20", role: .fraction)])
        // From 100 up a cost is drawn without its cents, rounded (134d, 134i).
        #expect(RecentUsageNumber.parts("$268.60", dropsCentsFromHundred: true)
            == [Part(text: "$", role: .symbol), Part(text: "269", role: .integer)])
        #expect(RecentUsageNumber.parts("¥1880.20", dropsCentsFromHundred: true)
            == [Part(text: "¥", role: .symbol), Part(text: "1880", role: .integer)])
        // Nothing spent reads 「$0」 (134s); a few cents keep theirs.
        #expect(RecentUsageNumber.parts("$0.00", dropsCentsFromHundred: true)
            == [Part(text: "$", role: .symbol), Part(text: "0", role: .integer)])
        #expect(RecentUsageNumber.parts("$0.0012", dropsCentsFromHundred: true).last == Part(text: "0012", role: .fraction))
        #expect(RecentUsageNumber.parts("65.5M")
            == [Part(text: "65", role: .integer), Part(text: "5", role: .fraction), Part(text: "M", role: .unit)])
        #expect(RecentUsageNumber.parts("6550万") == [Part(text: "6550", role: .integer), Part(text: "万", role: .unit)])
        #expect(RecentUsageNumber.parts("1,234") == [Part(text: "1,234", role: .integer)])
        #expect(RecentUsageNumber.parts("3h 12m") == [Part(text: "3", role: .integer), Part(text: "h", role: .unit),
                                                     Part(text: "12", role: .integer), Part(text: "m", role: .unit)])
        #expect(RecentUsageNumber.parts("—") == [Part(text: "—", role: .integer)])
    }

    @Test func figuresFollowThePanelUnitsAndTheYuanSignAsDrawn() {
        var units = UsagePanelState()
        let total = UsageDisplaySnapshot(buckets: [bucket("2026-11-27T02:00:00Z", cost: 41.2037, tokens: 65_500_000)],
                                         dataRange: .days(7), now: date("2026-11-27T07:42:00Z"),
                                         calendar: calendar).total
        var figures = RecentUsageFigures(total: total, activity: nil, units: units)
        #expect(figures.text(.cost) == "$41.20")
        #expect(figures.exactText(.cost) == "$41.2037")
        #expect(figures.unitHint(.cost) == "点一下换成人民币")
        #expect(figures.text(.token) == "65.5M")
        #expect(figures.exactText(.token) == "65,500,000")
        #expect(figures.text(.activeTime) == "—")

        units.toggleHeroUnit()
        figures = RecentUsageFigures(total: total, activity: ActivityTime(activeSeconds: 11_520, workSeconds: 16_128,
                                                                          parallel: 1.4), units: units)
        #expect(figures.text(.cost) == "¥288.43")
        #expect(figures.exactText(.cost) == "¥288.4259")
        #expect(figures.unitHint(.cost) == "点一下换成美元")
        #expect(figures.text(.activeTime) == "3h 12m")
        #expect(RecentUsageFigures.rows(besides: .token) == [.cost, .activeTime])
    }

    // MARK: Curve

    @Test func todayRunsFromTheFirstUsageHourToNowWithRoundTicks() throws {
        let now = date("2026-11-27T07:42:00Z")  // 15:42 in Singapore
        let costs = [3.2, 6.6, 6.1, 0.4, 7.6, 9.4, 7.9]
        let buckets = costs.enumerated().map { index, cost in
            bucket(date("2026-11-27T01:00:00Z").addingTimeInterval(Double(index) * 3_600).formatted(.iso8601), cost: cost)
        }
        let snapshot = UsageDisplaySnapshot(buckets: buckets, dataRange: .from(calendar.startOfDay(for: now)),
                                            now: now, calendar: calendar)
        let chart = RecentUsageChart(snapshot: snapshot, metric: .cost, activity: [], units: UsagePanelState(),
                                     rolling: false, now: now, calendar: calendar)
        #expect(chart.startLabel == "9:00")
        #expect(chart.endLabel == "现在")
        #expect(chart.ticks.map(\.label) == ["11:00", "13:00"])
        let span = 6.7 * 3_600
        #expect(abs(try #require(chart.ticks.first).x - 2 * 3_600 / span) < 0.001)
        #expect(chart.peak == 9.4 && chart.peakLabel == "$9.4")
        // A fixed start grows from zero at the left edge; the last slot sits
        // at the right edge, where the dot is.
        #expect(chart.curve.first == RecentUsageChart.Point(x: 0, value: 0))
        #expect(chart.curve.count == costs.count + 1)
        #expect(chart.hoverPoints.last?.x == 1)
        #expect(abs(chart.hoverPoints[0].x - 0.5 * 3_600 / span) < 0.001)
        #expect(chart.tooltips[2] == .line(period: "11:00–12:00", value: "$6.10"))
        #expect(chart.tooltips.last == .line(period: "15:00–15:42", value: "$7.90"))
    }

    @Test func rollingDayStartsAtItsFirstValueAndNamesYesterday() {
        let now = date("2026-11-27T07:42:00Z")
        var buckets = [bucket("2026-11-26T07:00:00Z", cost: 0.6), bucket("2026-11-26T13:00:00Z", cost: 2.9)]
        buckets.append(bucket("2026-11-27T07:00:00Z", cost: 8))
        let snapshot = UsageDisplaySnapshot(buckets: buckets, dataRange: .days(1), now: now, calendar: calendar)
        let chart = RecentUsageChart(snapshot: snapshot, metric: .cost, activity: [], units: UsagePanelState(),
                                     rolling: true, now: now, calendar: calendar)
        #expect(chart.startLabel == "昨天 15:00")
        #expect(chart.ticks.map(\.label) == ["0:00", "8:00"])
        #expect(chart.endLabel == "现在")
        #expect(chart.curve.first == RecentUsageChart.Point(x: 0, value: 0.6))
        #expect(chart.tooltips[6] == .line(period: "昨天 21:00–22:00", value: "$2.90"))
    }

    @Test func daysEndTodayOrOnTheirLastDayAndWeeksShowTheirSpan() {
        let now = date("2026-11-27T07:42:00Z")
        let week = UsageDisplaySnapshot(buckets: [bucket("2026-11-26T16:00:00Z", cost: 19)], dataRange: .days(7),
                                        now: now, calendar: calendar)
        let weekChart = RecentUsageChart(snapshot: week, metric: .cost, activity: [], units: UsagePanelState(),
                                         rolling: false, now: now, calendar: calendar)
        #expect(weekChart.startLabel == "11/21")
        #expect(weekChart.ticks.map(\.label) == ["11/23", "11/25"])
        #expect(weekChart.endLabel == "今天")
        #expect(weekChart.tooltips.last == .line(period: "11/27", value: "$19.00"))

        let custom = UsageDisplaySnapshot(buckets: [bucket("2026-11-10T16:00:00Z", cost: 5)],
                                          dataRange: .custom(from: date("2026-11-02T16:00:00Z"),
                                                             to: date("2026-11-17T16:00:00Z"),
                                                             timeZone: calendar.timeZone),
                                          now: now, calendar: calendar)
        let customChart = RecentUsageChart(snapshot: custom, metric: .cost, activity: [], units: UsagePanelState(),
                                           rolling: false, now: now, calendar: calendar)
        #expect(customChart.startLabel == "11/3")
        #expect(customChart.ticks.map(\.label) == ["11/8", "11/13"])
        #expect(customChart.endLabel == "11/18")

        let quarter = UsageDisplaySnapshot(buckets: [bucket("2026-11-20T16:00:00Z", cost: 8)], dataRange: .days(90),
                                           now: now, calendar: calendar)
        let quarterChart = RecentUsageChart(snapshot: quarter, metric: .cost, activity: [], units: UsagePanelState(),
                                            rolling: false, now: now, calendar: calendar)
        #expect(quarterChart.endLabel == "今天")
        #expect(quarterChart.tooltips.last == .line(period: "11/21–11/27", value: "$8.00"))
    }

    @Test func tokenHoverBreaksTheSlotDownAndPeakLabelsStayShort() {
        let now = date("2026-11-27T07:42:00Z")
        let snapshot = UsageDisplaySnapshot(buckets: [bucket("2026-11-27T06:00:00Z", cost: 9.4, tokens: 15_100_000)],
                                            dataRange: .from(calendar.startOfDay(for: now)), now: now, calendar: calendar)
        var units = UsagePanelState()
        units.hero = .token
        let chart = RecentUsageChart(snapshot: snapshot, metric: .token, activity: [], units: units,
                                     rolling: false, now: now, calendar: calendar)
        #expect(chart.peakLabel == "15M")
        #expect(chart.tooltips.first == .table(period: "14:00–15:00", rows: [
            .init(label: "总 Token", value: "15.1M"), .init(label: "输出", value: "1.5M"),
            .init(label: "输入", value: "1.5M"), .init(label: "缓存", value: "12.1M"),
        ]))

        units.toggleHeroUnit()
        #expect(RecentUsageChart.axisLabel(15_100_000, metric: .token, units: units) == "1510万")
        let plain = UsagePanelState()
        #expect(RecentUsageChart.axisLabel(1_510_000, metric: .token, units: plain) == "1.5M")
        #expect(RecentUsageChart.axisLabel(1_000_000_000, metric: .token, units: plain) == "1B")
        #expect(RecentUsageChart.axisLabel(950, metric: .token, units: plain) == "950")
        #expect(RecentUsageChart.axisLabel(63.2, metric: .cost, units: plain) == "$63")
        #expect(RecentUsageChart.axisLabel(5.17, metric: .cost, units: plain) == "$5.2")
        #expect(RecentUsageChart.axisLabel(0.5, metric: .cost, units: plain) == "$0.5")
        #expect(RecentUsageChart.axisLabel(2_880, metric: .activeTime, units: plain) == "48m")
    }

    // MARK: Activity

    @Test func activityCurveKnowsUnrecordedFromIdleAndIgnoresTheOtherGranularity() throws {
        let now = date("2026-11-27T07:42:00Z")
        let buckets = (1...6).map { bucket(date("2026-11-27T01:00:00Z").addingTimeInterval(Double($0) * 3_600)
            .formatted(.iso8601), cost: 1) } + [bucket("2026-11-27T01:00:00Z", cost: 1)]
        let snapshot = UsageDisplaySnapshot(buckets: buckets, dataRange: .from(calendar.startOfDay(for: now)),
                                            now: now, calendar: calendar)
        let response = UsageActivity(
            activeSeconds: 4_200, workSeconds: 5_880, parallel: 1.4,
            series: [.init(periodStart: "2026-11-27T03:00:00.000Z", activeSeconds: 1_200, workSeconds: 1_800),
                     .init(periodStart: "2026-11-27T05:00:00.000Z", activeSeconds: 3_000, workSeconds: 4_080)],
            firstBucketStart: "2026-11-27T02:30:00.000Z"
        )
        let report = ActivityReport(response, rangeStart: calendar.startOfDay(for: now), hourly: true,
                                    timeZone: calendar.timeZone)
        let times = RecentUsageChart.activity(report, grid: snapshot.grid)
        // 9:00 is before the first record; 10:00 holds it; 12:00 was idle.
        #expect(times.map { $0?.activeSeconds } == [nil, 0, 1_200, 0, 3_000, 0, 0])
        #expect(times[2]?.parallel == 1.5)
        #expect(times[4]?.parallel == 1.4)

        let chart = RecentUsageChart(snapshot: snapshot, metric: .activeTime, activity: times,
                                     units: UsagePanelState(), rolling: false, now: now, calendar: calendar)
        #expect(chart.peakLabel == "50m")
        #expect(chart.tooltips[0] == .line(period: "9:00–10:00", value: "—"))
        #expect(chart.tooltips[2] == .table(period: "11:00–12:00", rows: [
            .init(label: "活跃", value: "20m"), .init(label: "AI 工时", value: "30m"), .init(label: "平均同时", value: "1.5 个"),
        ]))

        let daily = ActivityReport(response, rangeStart: calendar.startOfDay(for: now), hourly: false,
                                   timeZone: calendar.timeZone)
        #expect(RecentUsageChart.activity(daily, grid: snapshot.grid).allSatisfy { $0 == nil })
        #expect(RecentUsageChart.activity(nil, grid: snapshot.grid).count == snapshot.grid.slots.count)
    }

    // MARK: Filters

    @Test func filterChipsNameTheFirstAndCountTheRest() {
        #expect(UsageFilterSummary.label([]) == nil)
        #expect(UsageFilterSummary.label(["Codex"]) == "Codex")
        #expect(UsageFilterSummary.label(["Cursor", "Codex"]) == "Codex +1")
        #expect(UsageFilterSummary.label(["Sonnet 5.5", "Opus 5.5", "Haiku 5.5"]) == "Haiku 5.5 +2")
        #expect(UsageFilterSummary.customLabel(from: date("2026-11-02T16:00:00Z"), to: date("2026-11-17T16:00:00Z"),
                                               calendar: calendar) == "11/3–11/18")
        #expect(UsageFilterSummary.customLabel(from: date("2026-11-17T16:00:00Z"), to: date("2026-11-17T16:00:00Z"),
                                               calendar: calendar) == "11/18")
    }

    @Test @MainActor
    func chipsSkipTheToolInsideASubscriptionAndLockItsRow() {
        let state = AppState(loadConfig: { nil })
        state.filters = FilterState(sources: ["cursor", "codex"], models: ["Opus 5.5"], projects: ["classic"],
                                    hostnames: [])
        var chips = UsageFilterChips(appState: state)
        #expect(chips.filters.map(\.title) == ["codex +1", "Opus 5.5"])
        #expect(chips.lockedTool == nil)
        let terminal = chips.value(.terminal, period: .today)
        #expect(terminal.text == "全部" && !terminal.isSet)
        let time = chips.value(.time, period: .sevenDays)
        #expect(time.text == "7D" && time.isSet && time.isMono)

        // Codex and Claude are enabled by default; opening Codex locks the tool.
        state.modernPanel.selectedSubscription = .codex
        chips = UsageFilterChips(appState: state)
        #expect(chips.lockedTool == "Codex")
        #expect(chips.filters.map(\.title) == ["Opus 5.5"])
        #expect(chips.value(.tool, period: .today).text == "Codex")
    }

    // MARK: Panel state

    @Test @MainActor
    func panelStateIsOneSetOfUsageControls() {
        let state = ModernPanelState()
        state.selectedSubscription = .cursor
        state.hero = .token
        state.usage.toggleHeroUnit()
        #expect(state.usage.selectedSubscription == .cursor && state.usage.hero == .token)
        let before = state.presentation
        state.panelDidOpen()
        #expect(state.presentation == before + 1)
        #expect(state.selectedSubscription == nil && state.hero == .cost && !state.detailsExpanded)
        // Units last for the app session.
        #expect(state.usage.usesChineseTokens)
    }
}
