import AppKit
import SwiftUI
import Testing
@testable import VibeUsage

/// The 近期消耗 card through SwiftUI's own update pass, in an off-screen
/// window that is never ordered in: reads that end before the next update
/// must still redraw it. Fake fetchers answer at once; nothing real is read.
@MainActor
struct RecentUsageCardTests {
    private final class Reads {
        var cost = 5.0
        var fails = false
    }

    /// An off-screen host for the card, reporting what it settled on.
    @MainActor
    private final class Card {
        private let window: NSWindow
        private let host: NSHostingView<AnyView>
        private let box: Box

        init(_ state: AppState, onActivityNumbers: (@MainActor (RecentUsageActivityShown) -> Void)? = nil) {
            var preview = RecentUsagePreview()
            let box = Box()
            preview.onShow = { box.value = $0 }
            preview.onActivityNumbers = onActivityNumbers
            self.box = box
            host = NSHostingView(rootView: AnyView(
                ModernRecentUsageBody()
                    .environment(state)
                    .environment(\.recentUsagePreview, preview)
                    .frame(width: 464, height: ModernTheme.cardBodyHeight)
            ))
            host.sizingOptions = []
            window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 464, height: ModernTheme.cardBodyHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 464, height: ModernTheme.cardBodyHeight)
        }

        private final class Box { var value: RecentUsageShown? }

        /// Lets SwiftUI run its next update, as the screen would.
        func update() async throws -> RecentUsageShown? {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
            return box.value
        }

    }

    private func makeState(_ reads: Reads) -> AppState {
        let config = VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test")
        let day = Calendar.current.startOfDay(for: Date()).formatted(.iso8601)
        _ = NSApplication.shared
        return AppState(
            initialConfig: config, loadConfig: { config },
            // Answers without suspending: the loading flag goes on and off
            // inside one turn, between two updates of the card.
            usageFetcher: { _, _, _ in
                if reads.fails { throw URLError(.notConnectedToInternet) }
                return UsageResponse(
                    buckets: [UsageBucket(source: "codex", model: "m", project: "p", hostname: "mac", bucketStart: day,
                                          inputTokens: 10, outputTokens: 0, cacheCreation5mTokens: nil,
                                          cacheCreation1hTokens: nil, cachedInputTokens: 0, reasoningOutputTokens: 0,
                                          totalTokens: 10, estimatedCost: reads.cost)],
                    sessions: nil, hasAnyData: true, names: nil
                )
            },
            activityFetcher: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) }
        )
    }

    @Test func aPeriodWhoseReadFailsAtOnceStopsFadingAndShowsDashes() async throws {
        let reads = Reads()
        let state = makeState(reads)
        state.timeRange = .today
        await state.fetchUsageData()
        let card = Card(state)
        #expect(try await card.update() == RecentUsageShown(kind: .figures, cost: 5))

        // 7D: the read follows in a task, the old figures fade meanwhile …
        state.timeRange = .sevenDays
        #expect(try await card.update()?.kind == .faded)
        // … and when it fails before the card's next update, 「—」, not the faded 5.
        reads.fails = true
        await state.fetchUsageData()
        #expect(try await card.update() == RecentUsageShown(kind: .unavailable, cost: nil))
    }

    @Test func aRefreshWithAsManyBucketsButOtherFiguresRedraws() async throws {
        let reads = Reads()
        let state = makeState(reads)
        state.timeRange = .sevenDays
        await state.fetchUsageData()
        let card = Card(state)
        #expect(try await card.update() == RecentUsageShown(kind: .figures, cost: 5))

        reads.cost = 9
        await state.fetchUsageData()
        #expect(try await card.update() == RecentUsageShown(kind: .figures, cost: 9))
    }

    @Test func subscriptionActivityHeroShowsTheSelectedToolsTimeAfterLoading() async throws {
        _ = NSApplication.shared
        let suite = "RecentUsageCard.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        var codex: CheckedContinuation<Void, Never>?
        let state = AppState(
            initialConfig: VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test"),
            loadConfig: { nil },
            usageFetcher: { _, _, range in RecentUsageFixtures.response(for: range, empty: false) },
            activityFetcher: { _, _, _, filters, _ in
                let isCodex = filters.sources == ["codex"]
                if isCodex { await withCheckedContinuation { codex = $0 } }
                let seconds = (isCodex ? 17 : 9) * 60
                return UsageActivity(activeSeconds: seconds, workSeconds: 2 * seconds, parallel: 2, series: [],
                                     firstBucketStart: "2020-01-01T00:00:00Z")
            },
            quotaDefaults: UserDefaults(suiteName: suite)!,
            interfaceStyle: InterfaceStylePreference(domain: suite, rollout: .externalTest)
        )
        state.modernPanel.hero = .activeTime
        state.filters.sources = ["claude-code"]
        await state.fetchUsageData()
        try await waitForDashboard { state.activity != nil }
        // AI 工时 comes with active time and loads with it.
        var displayed: [RecentUsageActivityShown] = []
        let card = Card(state) { displayed.append($0) }
        _ = try await card.update()
        #expect(displayed.last == RecentUsageActivityShown(active: "9m", work: "18m"))
        state.modernPanel.selectedSubscription = .codex
        try await waitForDashboard { codex != nil }
        _ = try await card.update()
        #expect(displayed == [RecentUsageActivityShown(active: "9m", work: "18m"),
                              RecentUsageActivityShown(active: nil, work: nil)])
        codex?.resume()
        try await waitForDashboard { state.activity != nil }
        _ = try await card.update()
        #expect(displayed.last == RecentUsageActivityShown(active: "17m", work: "34m"))
        state.modernPanel.selectedSubscription = nil
        try await waitForDashboard { state.activity != nil }
        _ = try await card.update()
        #expect(displayed.last == RecentUsageActivityShown(active: "9m", work: "18m"))
    }
}
