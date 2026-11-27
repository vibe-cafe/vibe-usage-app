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

    @Test func tokensUseThreeSignificantDigitsAndDurationsPadMinutes() {
        // The design's figures (134a–134l); the classic formatter is untouched.
        let expected: [(Int, String)] = [
            (1_040_000_000, "1.04B"), (421_000_000, "421M"), (93_100_000, "93.1M"), (210_000, "210K"),
            (65_500_000, "65.5M"), (12_000_000, "12M"), (999_950, "1M"), (999_449_999, "999M"),
            (1_234, "1.23K"), (950, "950"), (0, "0"), (999_949_999, "1B"),
        ]
        for (tokens, text) in expected {
            #expect(Formatters.formatPanelTokens(tokens) == text, "\(tokens)")
        }
        #expect(Formatters.formatNumber(421_000_000) == "421.0M")
        var units = UsagePanelState()
        #expect(units.formatTokens(421_000_000) == "421M")
        units.hero = .token
        units.toggleHeroUnit()
        #expect(units.formatTokens(65_500_000) == "6550万")

        let durations: [(Int, String)] = [(0, "0m"), (30, "30s"), (2_880, "48m"), (11_520, "3h 12m"),
                                          (68_700, "19h 05m"), (169_200, "47h")]
        for (seconds, text) in durations {
            #expect(RecentUsageNumber.duration(seconds) == text, "\(seconds)")
        }
        #expect(ActivityTime.duration(68_700) == "19h 5m")
        let report = ActivityReport(UsageActivity(activeSeconds: 11_520, workSeconds: 16_080, parallel: 1.4,
                                                  series: [], firstBucketStart: "2026-01-01T00:00:00Z"),
                                    rangeStart: date("2026-11-27T00:00:00Z"), hourly: true)
        #expect(report.summaryHelp(duration: RecentUsageNumber.duration) == "AI 工时 4h 28m · 平均同时 1.4 个")
        #expect(report.summaryHelp == "AI 工时 4h 28m · 平均同时 1.4 个")
    }

    // MARK: Activity requests and the style

    @MainActor
    private func modernState(_ suite: String, activity: @escaping (UsageQueryRange, FilterState, Bool) throws -> UsageActivity,
                             usageReads: @escaping () -> Void = {}) -> AppState {
        let config = VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test")
        return AppState(
            initialConfig: config, loadConfig: { config },
            usageFetcher: { _, _, _ in
                usageReads()
                return UsageResponse(buckets: [], sessions: nil, hasAnyData: true, names: nil)
            },
            activityFetcher: { _, _, range, filters, hourly in try activity(range, filters, hourly) },
            interfaceStyle: InterfaceStylePreference(domain: suite, rollout: .externalTest)
        )
    }

    @Test @MainActor
    func switchingToClassicWithoutReadingAgainSumsTheSingleDaysHours() async throws {
        let suite = "RecentUsageDisplayTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let day = Calendar.current.startOfDay(for: Date().addingTimeInterval(-9 * 86_400))
        var reads = 0
        let state = modernState(suite, activity: { _, _, hourly in
            reads += 1
            #expect(hourly)
            return UsageActivity(
                activeSeconds: 4_200, workSeconds: 5_880, parallel: 1.4,
                series: [.init(periodStart: day.addingTimeInterval(9 * 3_600).formatted(.iso8601),
                               activeSeconds: 1_200, workSeconds: 1_800),
                         .init(periodStart: day.addingTimeInterval(15 * 3_600).formatted(.iso8601),
                               activeSeconds: 3_000, workSeconds: 4_080)],
                firstBucketStart: day.addingTimeInterval(-30 * 86_400).formatted(.iso8601)
            )
        })
        state.customRangeFrom = day
        state.customRangeTo = day
        state.timeRange = .custom
        await state.fetchUsageData()
        try await waitForDashboard { state.activity != nil }

        // The classic chart asks by day; the style switch alone reads nothing.
        state.interfaceStyle.select(.classic)
        let key = Formatters.localDayKey(day.formatted(.iso8601))
        #expect(state.activity?.time(in: key) == ActivityTime(activeSeconds: 4_200, workSeconds: 5_880, parallel: 1.4))
        let before = Formatters.localDayKey(day.addingTimeInterval(-40 * 86_400).formatted(.iso8601))
        #expect(state.activity?.time(in: before) == nil)
        await Task.yield()
        #expect(reads == 1)
    }

    @Test @MainActor
    func theNewPanelLeavesTheClassicProjectOutOfItsActivityRequest() async throws {
        let suite = "RecentUsageDisplayTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        var asked: [FilterState] = []
        let state = modernState(suite, activity: { _, filters, _ in
            asked.append(filters)
            throw URLError(.notConnectedToInternet)
        })
        state.filters = FilterState(sources: ["codex"], projects: ["A"])
        await state.fetchUsageData()
        try await waitForDashboard { asked.count == 1 }
        #expect(asked.last == FilterState(sources: ["codex"]))
        #expect(state.filters.projects == ["A"])  // the classic selection stays
        // A project change does not change the new panel's request.
        state.filters.projects = ["B"]
        await Task.yield()
        #expect(asked.count == 1)

        state.interfaceStyle.select(.classic)
        await state.fetchUsageData()
        try await waitForDashboard { asked.count == 2 }
        #expect(asked.last == FilterState(sources: ["codex"], projects: ["B"]))
    }

    @Test @MainActor
    func eachStyleStartsOnItsDefaultPeriodAndAChangedPeriodIsReadAgain() async throws {
        let suite = "RecentUsageDisplayTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        var reads = 0
        let state = modernState(suite, activity: { _, _, _ in throw URLError(.notConnectedToInternet) },
                                usageReads: { reads += 1 })
        #expect(state.timeRange == .oneDay)
        state.applyDefaultTimeRangeForInterfaceStyle()  // what initialize() does before the launch fetch
        #expect(state.timeRange == .today)

        state.selectInterfaceStyle(.classic)
        #expect(state.timeRange == .oneDay)
        try await waitForDashboard { reads == 1 }
        state.selectInterfaceStyle(.classic)  // no change, nothing read
        state.timeRange = .today
        state.selectInterfaceStyle(.modern)   // already on 今天: nothing read
        #expect(state.timeRange == .today)
        state.selectInterfaceStyle(.classic)
        try await waitForDashboard { reads == 2 }
        await Task.yield()
        #expect(reads == 2)
    }

    @Test @MainActor
    func aStyleSwitchThatKeepsThePeriodReadsOnlyActiveTimeWhenTheProjectsDiffer() async throws {
        let suite = "RecentUsageDisplayTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        var asked: [FilterState] = []
        var usageReads = 0
        let state = modernState(suite, activity: { _, filters, _ in
            asked.append(filters)
            return UsageActivity(activeSeconds: 60, workSeconds: 60, parallel: 1, series: [],
                                 firstBucketStart: "2026-01-01T00:00:00Z")
        }, usageReads: { usageReads += 1 })
        // Classic, 今天 and project A, read.
        state.interfaceStyle.select(.classic)
        state.timeRange = .today
        state.filters = FilterState(projects: ["A"])
        await state.fetchUsageData()
        try await waitForDashboard { state.activity != nil }
        #expect(usageReads == 1 && asked == [FilterState(projects: ["A"])])

        // The new panel also opens on 今天 but counts every project: the old
        // active time goes, and only it is read again. Nobody calls fetchUsageData().
        state.selectInterfaceStyle(.modern)
        #expect(state.timeRange == .today)
        #expect(state.activity == nil)
        try await waitForDashboard { asked.count == 2 && state.activity != nil }
        #expect(asked.last == FilterState())
        #expect(usageReads == 1)

        // Same period and the same conditions both ways: nothing is read.
        state.filters = FilterState()
        state.interfaceStyle.select(.classic)
        state.timeRange = .today
        state.selectInterfaceStyle(.modern)
        await Task.yield()
        #expect(asked.count == 2 && usageReads == 1)
    }

    @Test @MainActor
    func aModelUsedOnlyInTheAfternoonDoesNotCutTheMorningsActiveTime() async throws {
        let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let afternoon = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
        let now = Calendar.current.date(bySettingHour: 16, minute: 30, second: 0, of: Date())!
        func row(_ start: Date, model: String) -> UsageBucket {
            UsageBucket(source: "codex", model: model, project: "p", hostname: "mac", bucketStart: start.formatted(.iso8601),
                        inputTokens: 10, outputTokens: 0, cacheCreation5mTokens: nil, cacheCreation1hTokens: nil,
                        cachedInputTokens: 0, reasoningOutputTokens: 0, totalTokens: 10, estimatedCost: 1)
        }
        let config = VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test")
        let state = AppState(
            initialConfig: config, loadConfig: { config },
            usageFetcher: { _, _, _ in
                UsageResponse(buckets: [row(morning, model: "A"), row(afternoon, model: "B")], sessions: nil,
                              hasAnyData: true, names: nil)
            },
            activityFetcher: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) }
        )
        state.timeRange = .today
        await state.fetchUsageData()
        let onlyB = UsagePanelFilters(models: ["B"])
        // Cost and Tokens of B start at 15:00 …
        #expect(state.usageDisplaySnapshot(filters: onlyB, now: now)?.grid.slots.first?.start == afternoon)
        // … but active time, which no model filter narrows, starts in the morning.
        let grid = try #require(state.activityPlotGrid(filters: onlyB, now: now))
        #expect(grid.slots.first?.start == morning)
        #expect(grid.slots.count == 8)
        // A tool filter does narrow it.
        #expect(state.activityPlotGrid(filters: UsagePanelFilters(sources: ["codex"], models: ["B"]), now: now)?
            .slots.first?.start == morning)
        let other = try #require(state.activityPlotGrid(filters: UsagePanelFilters(sources: ["cursor"]), now: now))
        #expect(other.slots.first?.start == Calendar.current.startOfDay(for: now))
    }

    @Test @MainActor
    func relinkingDropsThePreviousAccountsFiguresBeforeTheNewOnesArrive() async throws {
        let day = Calendar.current.startOfDay(for: Date()).formatted(.iso8601)
        func response(cost: Double) -> UsageResponse {
            UsageResponse(buckets: [UsageBucket(source: "codex", model: "m", project: "p", hostname: "mac", bucketStart: day,
                                                inputTokens: 10, outputTokens: 0, cacheCreation5mTokens: nil,
                                                cacheCreation1hTokens: nil, cachedInputTokens: 0,
                                                reasoningOutputTokens: 0, totalTokens: 10, estimatedCost: cost)],
                          sessions: nil, hasAnyData: true, names: nil)
        }
        var current = VibeUsageConfig(apiKey: "A", apiUrl: "https://example.test")
        var waitingForB: CheckedContinuation<Void, Never>?
        let state = AppState(
            initialConfig: current, loadConfig: { current },
            usageFetcher: { _, key, _ in
                if key == "B" { await withCheckedContinuation { waitingForB = $0 } }
                return response(cost: key == "A" ? 5 : 9)
            },
            activityFetcher: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) }
        )
        state.timeRange = .sevenDays
        let keeper = UsageFiguresKeeper()
        func shown() -> (cost: Double?, faded: Bool, loading: Bool) {
            switch keeper.figures(state, filters: .init()) {
            case .figures(let snapshot, let faded): (snapshot.total.cost, faded, false)
            case .loading: (nil, false, true)
            case .unavailable: (nil, false, false)
            }
        }
        await state.fetchUsageData()
        #expect(shown().cost == 5)

        // Relinked to B; B's answer comes later. A's figures are gone at once.
        current = VibeUsageConfig(apiKey: "B", apiUrl: "https://example.test")
        let read = Task { await state.fetchUsageData() }
        try await waitForDashboard { waitingForB != nil }
        let meanwhile = shown()
        #expect(meanwhile.loading && meanwhile.cost == nil)
        waitingForB?.resume()
        await read.value
        let after = shown()
        #expect(after.cost == 9 && !after.faded)

        // A new period before its read has even started (it follows in a
        // task): the previous figures fade, no 「—」 flash.
        state.timeRange = .thirtyDays
        let pending = shown()
        #expect(pending.cost == 9 && pending.faded)

        // A read that brought nothing reads 「—」, not zero.
        let unread = RecentUsageFigures(total: nil, activity: nil, units: UsagePanelState())
        #expect(unread.text(.cost) == "—" && unread.text(.token) == "—" && unread.exactText(.cost) == nil)
    }

    @Test @MainActor
    func openingThePanelClosesTheFilterMenu() {
        let state = ModernPanelState()
        state.filterMenu.open(.tool)
        #expect(state.filterMenu.isOpen)
        state.panelDidOpen()
        #expect(!state.filterMenu.isOpen && state.filterMenu.submenu == nil)
    }

    // MARK: Activity granularity

    @Test @MainActor
    func aSingleCustomDayAsksActivityByTheHourOnlyInTheNewPanel() async throws {
        let suite = "RecentUsageDisplayTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        var asked: [Bool] = []
        let config = VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test")
        let state = AppState(
            initialConfig: config, loadConfig: { config },
            usageFetcher: { _, _, _ in UsageResponse(buckets: [], sessions: nil, hasAnyData: true, names: nil) },
            activityFetcher: { _, _, _, _, hourly in
                asked.append(hourly)
                throw URLError(.notConnectedToInternet)
            },
            interfaceStyle: InterfaceStylePreference(domain: suite, rollout: .externalTest)
        )
        #expect(state.interfaceStyle.current == .modern)
        let day = Calendar.current.startOfDay(for: Date().addingTimeInterval(-9 * 86_400))
        // Each read waits for its activity request (a new read cancels the previous one).
        func read() async throws {
            let before = asked.count
            await state.fetchUsageData()
            try await waitForDashboard { asked.count == before + 1 }
        }
        state.customRangeFrom = day
        state.customRangeTo = day
        state.timeRange = .custom
        try await read()
        state.customRangeTo = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        try await read()
        state.timeRange = .today
        try await read()
        state.interfaceStyle.select(.classic)
        state.customRangeTo = day
        state.timeRange = .custom
        try await read()
        #expect(asked == [true, false, true, false])
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
            .init(label: "总 Token", value: "15.1M"), .init(label: "输出", value: "1.51M"),
            .init(label: "输入", value: "1.51M"), .init(label: "缓存", value: "12.1M"),
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
        // The unknown 9:00 is not drawn as idle: the curve starts at the
        // first known slot (10:00), and the known idle 12:00 stays on zero.
        #expect(!chart.hoverPoints[0].isKnown && chart.hoverPoints[1].isKnown)
        #expect(chart.curve.first == chart.hoverPoints[1])
        #expect(chart.curve.count == 6 && chart.curve.contains(chart.hoverPoints[3]))
        #expect(chart.hoverPoints[3].value == 0)
        // With nothing unknown, a fixed start still grows from zero at the left edge.
        let full = RecentUsageChart(snapshot: snapshot, metric: .activeTime,
                                    activity: times.map { $0 ?? ActivityTime(activeSeconds: 0, workSeconds: 0, parallel: nil) },
                                    units: UsagePanelState(), rolling: false, now: now, calendar: calendar)
        #expect(full.curve.first == RecentUsageChart.Point(x: 0, value: 0))

        let daily = ActivityReport(response, rangeStart: calendar.startOfDay(for: now), hourly: false,
                                   timeZone: calendar.timeZone)
        #expect(RecentUsageChart.activity(daily, grid: snapshot.grid).allSatisfy { $0 == nil })
        #expect(RecentUsageChart.activity(nil, grid: snapshot.grid).count == snapshot.grid.slots.count)
    }

    @Test func theEmptyStateFollowsTheBigNumberAndAModelFilterKeepsActiveTime() {
        let now = date("2026-11-27T07:42:00Z")
        // A model filter left no usage in the week, but active time was recorded.
        let snapshot = UsageDisplaySnapshot(buckets: [bucket("2026-11-25T02:00:00Z", cost: 3)], dataRange: .days(7),
                                            filters: UsagePanelFilters(models: ["Other"]), now: now, calendar: calendar)
        #expect(snapshot.series.isEmpty)
        let response = UsageActivity(
            activeSeconds: 5_400, workSeconds: 7_200, parallel: 1.3,
            series: [.init(periodStart: "2026-11-23T16:00:00.000Z", activeSeconds: 1_800, workSeconds: 2_400),
                     .init(periodStart: "2026-11-24T16:00:00.000Z", activeSeconds: 3_600, workSeconds: 4_800)],
            firstBucketStart: "2026-01-01T00:00:00.000Z"
        )
        let report = ActivityReport(response, rangeStart: date("2026-11-20T16:00:00Z"), hourly: false,
                                    timeZone: calendar.timeZone)
        #expect(RecentUsageChart.isEmpty(.cost, snapshot: snapshot, activity: report))
        #expect(RecentUsageChart.isEmpty(.token, snapshot: snapshot, activity: report))
        #expect(!RecentUsageChart.isEmpty(.activeTime, snapshot: snapshot, activity: report))
        // Active time that has not arrived is not 「暂无数据」; none recorded is.
        #expect(!RecentUsageChart.isEmpty(.activeTime, snapshot: snapshot, activity: nil))
        let idle = ActivityReport(UsageActivity(activeSeconds: 0, workSeconds: 0, parallel: nil, series: [],
                                                firstBucketStart: "2026-01-01T00:00:00.000Z"),
                                  rangeStart: date("2026-11-20T16:00:00Z"), hourly: false, timeZone: calendar.timeZone)
        #expect(RecentUsageChart.isEmpty(.activeTime, snapshot: snapshot, activity: idle))

        // The curve then uses the week's whole grid.
        let grid = UsagePlotGrid(dataRange: .days(7), now: now, calendar: calendar)
        let chart = RecentUsageChart(activityGrid: grid, activity: RecentUsageChart.activity(report, grid: grid),
                                     units: UsagePanelState(), rolling: false, now: now, calendar: calendar)
        #expect(chart.hoverPoints.count == 7)
        #expect(chart.hoverPoints.map(\.value) == [0, 0, 0, 1_800, 3_600, 0, 0])
        #expect(chart.peakLabel == "1h")
        #expect(chart.endLabel == "今天")
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
