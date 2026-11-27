import AppKit
import SwiftUI
import Testing
@testable import VibeUsage

/// 展开详情 (135): the ring's tick runs, where 「其余 N 个」 opens its list,
/// the card metrics and filters the cards count with, and the fixed card
/// height. Fixture usage only; nothing real is read.
struct ModernDetailsTests {
    // MARK: Ring

    /// Runs of one owner, gaps included: `[(owner, count)]` in tick order.
    private func runs(_ owners: [Int?]) -> [(Int?, Int)] {
        var result: [(Int?, Int)] = []
        for owner in owners {
            if let last = result.last, last.0 == owner {
                result[result.count - 1].1 += 1
            } else {
                result.append((owner, 1))
            }
        }
        return result
    }

    @Test
    func ringRunsMatchTheDrawingOf135a() {
        // 模型分布: 30.9 / 16.2 / 11.4 / rest 7.0 → 34, 18, 12, 8 ticks, the
        // last of each the gap.
        let models = runs(ModernDistributionRing.tickOwners([30.9, 16.2, 11.4, 7.0]))
        #expect(models.map(\.0) == [0, nil, 1, nil, 2, nil, 3, nil])
        #expect(models.map(\.1) == [33, 1, 17, 1, 11, 1, 7, 1])

        // Token 构成: 95 / 4 / 1 % → 67 + gap, 2 + gap, and one lit tick
        // that has no room for a gap.
        let composition = runs(ModernDistributionRing.tickOwners([62.2, 2.6, 0.7]))
        #expect(composition.map(\.0) == [0, nil, 1, nil, 2])
        #expect(composition.map(\.1) == [67, 1, 2, 1, 1])

        // 工具分布 of 135b: one tool is a closed ring.
        #expect(ModernDistributionRing.tickOwners([104]) == Array(repeating: 0, count: 72))
    }

    @Test
    func everyShareKeepsATickAndTheRingStaysWhole() {
        let owners = ModernDistributionRing.tickOwners([1_000, 1, 1, 0])
        #expect(owners.count == 72)
        #expect(owners.filter { $0 == 1 }.count == 1)
        #expect(owners.filter { $0 == 2 }.count == 1)
        #expect(!owners.contains(3))
        // Nothing to divide (a period without cost): every tick off.
        #expect(ModernDistributionRing.tickOwners([0, 0, 0]) == Array(repeating: nil, count: 72))
        #expect(ModernDistributionRing.tickOwners([]) == Array(repeating: nil, count: 72))
    }

    // MARK: 「其余 N 个」

    @Test
    func remainderListOpensUnderItsRowAndAboveItAtTheBottomOfTheGrid() {
        let grid = CGRect(x: 0, y: 0, width: 496, height: 512)
        let row = CGRect(x: 16, y: 214, width: 212, height: 22)
        // 135d: the top-left card's row (16 + 20 + 8 + 4 + 88 + 12 + 3 × 22).
        let top = RemainderListPlacement.frame(trigger: row, rows: 3, visible: grid)
        #expect(top == CGRect(x: 7, y: 238, width: 230, height: 76))
        // The same row on a bottom card would leave the grid: it opens upward.
        let bottom = RemainderListPlacement.frame(
            trigger: CGRect(x: 268, y: 474, width: 212, height: 22), rows: 3, visible: grid)
        #expect(bottom == CGRect(x: 259, y: 396, width: 230, height: 76))
        // Twelve rows show nine and a half.
        let long = RemainderListPlacement.frame(trigger: row, rows: 12, visible: grid)
        let nineAndAHalfRows: CGFloat = 5 + 22 * 9.5
        #expect(long.height == nineAndAHalfRows)
        #expect(long.minY == 238)
    }

    /// A short screen, scrolled: only part of the grid is on screen, and the
    /// list goes where it can be seen.
    @Test
    func remainderListStaysInTheVisiblePartOfAScrolledPanel() {
        let row = CGRect(x: 16, y: 214, width: 212, height: 22)
        // The row sits just above the footer (on screen: −240…240 of the
        // grid): the list opens upward, over the cards above it.
        let atFooter = RemainderListPlacement.frame(
            trigger: row, rows: 3, visible: CGRect(x: 0, y: -240, width: 496, height: 480))
        #expect(atFooter == CGRect(x: 7, y: 136, width: 230, height: 76))
        // Neither side holds three rows (on screen: 150…270): the roomier
        // side, shortened so that it scrolls.
        let squeezed = RemainderListPlacement.frame(
            trigger: row, rows: 3, visible: CGRect(x: 0, y: 150, width: 496, height: 120))
        #expect(squeezed == CGRect(x: 7, y: 150, width: 230, height: 62))
        #expect(squeezed.height < RemainderListPlacement.height(rows: 3))
        // Hardly any room on either side: still a row and a half.
        let edge = RemainderListPlacement.frame(
            trigger: row, rows: 3, visible: CGRect(x: 0, y: 205, width: 496, height: 40))
        let rowAndAHalf: CGFloat = 38
        #expect(edge.height == rowAndAHalf)
    }

    // MARK: What a card shows

    private func kind(_ figures: UsageFigures) -> String {
        switch figures {
        case .loading: "loading"
        case .unavailable: "unavailable"
        case .figures(let snapshot, let faded):
            faded ? "faded" : snapshot.grid.slots.isEmpty ? "zero" : "figures"
        }
    }

    @Test @MainActor
    func onlyASuccessfulReadOfThePeriodDrawsFiguresOrZero() async {
        var fails = false
        var empty = false
        let stamp = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600))
        let used = UsageBucket(
            source: "codex", model: "m", project: "p", hostname: "mac", bucketStart: stamp,
            inputTokens: 100, outputTokens: 0, cacheCreation5mTokens: nil, cacheCreation1hTokens: nil,
            cachedInputTokens: 0, reasoningOutputTokens: 0, totalTokens: 100, estimatedCost: 1)
        let state = AppState(
            initialConfig: VibeUsageConfig(apiKey: "one", apiUrl: "https://example.test"),
            loadConfig: { nil },
            usageFetcher: { _, _, _ in
                if fails { throw URLError(.timedOut) }
                return UsageResponse(buckets: empty ? [] : [used], sessions: nil, hasAnyData: true, names: nil)
            },
            activityFetcher: { _, _, _, _ in throw URLError(.notConnectedToInternet) }
        )
        state.timeRange = .today
        let keeper = UsageFiguresKeeper()
        func shown() -> String { kind(keeper.figures(state, filters: .init())) }

        // Nothing read yet, then a first read that fails: never a zero.
        #expect(shown() == "loading")
        fails = true
        await state.fetchUsageData()
        #expect(shown() == "unavailable")

        fails = false
        await state.fetchUsageData()
        #expect(shown() == "figures")

        // The same period read again without success keeps its figures.
        fails = true
        await state.fetchUsageData()
        #expect(shown() == "figures")

        // A new period: the previous figures fade while its read runs, and
        // only until it ends — a failure is 「—」, not the old numbers, and a
        // retry shows loading blocks, not the old numbers again.
        state.timeRange = .sevenDays
        state.isLoadingData = true
        #expect(shown() == "faded")
        await state.fetchUsageData()
        #expect(shown() == "unavailable")
        state.isLoadingData = true
        #expect(shown() == "loading")

        // Zero only for a period read successfully without usage.
        fails = false
        empty = true
        await state.fetchUsageData()
        #expect(shown() == "zero")
        empty = false
        await state.fetchUsageData()
        #expect(shown() == "figures")

        // Another account: the previous one's figures are gone at once, even
        // while the new account's first read runs.
        state.applyConfig(VibeUsageConfig(apiKey: "two", apiUrl: "https://example.test"))
        #expect(shown() == "loading")
        state.isLoadingData = true
        #expect(shown() == "loading")
    }

    @Test @MainActor
    func theAccountChangesOnlyWithTheKeyOrTheServer() async {
        let linked = VibeUsageConfig(apiKey: "one", apiUrl: "https://example.test")
        let suite = "ModernDetailsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(
            initialConfig: linked,
            loadConfig: { linked },
            usageFetcher: { _, _, _ in UsageResponse(buckets: [], sessions: nil, hasAnyData: false, names: nil) },
            activityFetcher: { _, _, _, _ in throw URLError(.notConnectedToInternet) },
            quotaDefaults: defaults
        )
        let start = state.usageAccount
        // An ordinary refresh re-reads the same key on the same server.
        await state.fetchUsageData()
        state.applyConfig(linked)
        #expect(state.usageAccount == start)
        // The same key on another server.
        state.applyConfig(VibeUsageConfig(apiKey: "one", apiUrl: "https://other.test"))
        let movedServer = state.usageAccount
        #expect(movedServer != start)
        // Another key (a relink).
        state.applyConfig(VibeUsageConfig(apiKey: "two", apiUrl: "https://other.test"))
        let relinked = state.usageAccount
        #expect(relinked != movedServer)
        // 「重置配置」.
        state.applyConfig(nil)
        #expect(state.usageAccount != relinked)
    }

    @Test
    func figuresRuleCoversEveryReadState() {
        let snapshot = UsageDisplaySnapshot(buckets: [], dataRange: .days(7), now: Date())
        func shown(_ current: UsageDisplaySnapshot?, _ retained: UsageDisplaySnapshot?,
                   loading: Bool, finished: Bool) -> String {
            kind(UsageFigures.resolve(current: current, retained: retained, isLoading: loading,
                                      hasFinishedRead: finished))
        }
        let refreshing = shown(snapshot, nil, loading: true, finished: true)
        let changingPeriod = shown(nil, snapshot, loading: true, finished: true)
        let firstRead = shown(nil, nil, loading: true, finished: true)
        let failed = shown(nil, snapshot, loading: false, finished: true)
        let notYetRead = shown(nil, nil, loading: false, finished: false)
        #expect(refreshing == "zero")
        #expect(changingPeriod == "faded")
        #expect(firstRead == "loading")
        #expect(failed == "unavailable")
        #expect(notYetRead == "loading")
    }

    @Test
    func sharesReadAsWholePercentsAndATinyShareStaysVisible() {
        #expect(DetailsFormat.share(30.9 / 65.5) == "47%")
        #expect(DetailsFormat.share(1) == "100%")
        #expect(DetailsFormat.share(0.004) == "<1%")
        #expect(DetailsFormat.share(0) == "0%")
    }

    @Test
    func tokenFiguresTakeTheUnitOfTheCardsTotal() {
        func tokens(_ value: Double, of total: Double) -> String {
            DetailsFormat.value(value, .tokens, cardTotal: total)
        }
        // 135a: one card, one unit, one decimal.
        #expect(tokens(65_500_000, of: 65_500_000) == "65.5M")
        #expect(tokens(62_200_000, of: 65_500_000) == "62.2M")
        #expect(tokens(700_000, of: 65_500_000) == "0.7M")
        #expect(tokens(7_000_000, of: 65_500_000) == "7.0M")
        // 135b: no decimal from 100 up.
        #expect(tokens(104_000_000, of: 104_000_000) == "104M")
        #expect(tokens(1_000_000, of: 104_000_000) == "1.0M")
        // A sliver of a large card still reads as present.
        #expect(tokens(20_000, of: 65_500_000) == "<0.1M")
        // Other totals pick their own unit; under a thousand is a plain count.
        #expect(tokens(1_500_000_000, of: 2_100_000_000) == "1.5B")
        #expect(tokens(999_600, of: 999_600) == "1.0M")
        #expect(tokens(48_000, of: 120_000) == "48.0K")
        #expect(tokens(850, of: 850) == "850")
        #expect(tokens(0, of: 0) == "0")
        // Cost keeps the app's format.
        #expect(DetailsFormat.value(41.2, .cost, cardTotal: 41.2) == "$41.20")
        // The app's general formatter is unchanged.
        #expect(Formatters.formatNumber(700_000) == "700.0K")
    }

    @Test
    func aLoneFourthRowIsListedAndTwoOrMoreCollapse() {
        let four = UsageRanking(values: ["A": 4, "B": 3, "C": 2, "D": 1])
        #expect(four.listed.map(\.name) == ["A", "B", "C", "D"])
        #expect(four.listed.map(\.color) == [.blue, .teal, .magenta, .gray])
        #expect(four.collapsed.isEmpty)

        let five = UsageRanking(values: ["A": 5, "B": 4, "C": 3, "D": 2, "E": 1])
        #expect(five.listed.map(\.name) == ["A", "B", "C"])
        #expect(five.collapsed.map(\.name) == ["D", "E"])
        #expect(five.remainderValue == 3)

        let three = UsageRanking(values: ["A": 3, "B": 2, "C": 1])
        #expect(three.listed.count == 3 && three.collapsed.isEmpty)
    }

    @Test
    func tokenCompositionKeepsCacheInputOutputWhicheverIsLargest() {
        let ordered = UsageRanking(ordered: [("缓存", 10), ("输入", 300), ("输出", 50)])
        #expect(ordered.listed.map(\.name) == ["缓存", "输入", "输出"])
        #expect(ordered.listed.map(\.color) == [.blue, .teal, .magenta])
        #expect(ordered.total == 360)
    }

    // MARK: State

    @Test @MainActor
    func cardMetricsAreSeparateAndOutliveAnOpen() {
        let state = ModernPanelState()
        #expect(state[metricFor: .model] == .tokens)
        state[metricFor: .model] = .cost
        #expect(state[metricFor: .terminal] == .tokens && state[metricFor: .tool] == .tokens)
        state.panelDidOpen()
        #expect(state[metricFor: .model] == .cost)
    }

    @Test @MainActor
    func cardsCountWhatTheSelectedSubscriptionCounts() async throws {
        let fixture = PanelFixture(PanelScene(id: "filters", title: "筛选", expanded: true, usage: .today))
        defer { fixture.tearDown() }
        try await fixture.prepare()
        let state = fixture.state
        func tools() -> [String] {
            let filters = state.modernPanel.usageFilters(state.filters, enabled: state.quotaCardProviders)
            let snapshot = state.usageDisplaySnapshot(filters: filters, now: Date())
            let ranking = snapshot?.ranking(.tool, by: .tokens)
            return (ranking?.top.map(\.name) ?? []) + (ranking?.remainder.map(\.name) ?? [])
        }
        #expect(tools() == ["Claude Code", "Codex", "Cursor"])
        state.modernPanel.selectedSubscription = .codex
        #expect(tools() == ["Codex"])
        // A manual tool filter gives way to the subscription, then comes back.
        state.filters.sources = ["cursor"]
        #expect(tools() == ["Codex"])
        state.modernPanel.selectedSubscription = nil
        #expect(tools() == ["Cursor"])
    }

    // MARK: Height

    /// The four cards are 252 pt whatever they hold, and an open list hangs
    /// over them without moving anything: the panel's height is the shell's.
    @Test @MainActor
    func detailsKeepTheirHeightWithFiguresAndAnOpenList() async throws {
        _ = NSApplication.shared
        let fixture = PanelFixture(PanelScene(id: "height", title: "高度", usage: .today))
        defer { fixture.tearDown() }
        try await fixture.prepare()
        for open: UsageRanking.Dimension? in [nil, .model] {
            let host = NSHostingView(rootView: ModernDetailsSection(openRemainder: open)
                .frame(width: ModernTheme.panelWidth - 2 * ModernTheme.cardInset)
                .environment(fixture.state))
            host.sizingOptions = [.intrinsicContentSize]
            host.layoutSubtreeIfNeeded()
            let twoCardRows: CGFloat = 2 * 252 + ModernTheme.cardSpacing
            #expect(host.fittingSize.height == twoCardRows)
        }
    }
}
