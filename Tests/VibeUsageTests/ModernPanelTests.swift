import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VibeUsage

/// The new panel's shell: navigation reset, the split between 「同步用量」 and
/// 「刷新额度」, the height rule, the footer's sync label and the bundled fonts.
/// Isolated preferences, fake quota readers and a fake sync: nothing here reads
/// a real account, config or Keychain item, or starts the CLI.
struct ModernPanelTests {
    // MARK: Navigation

    @Test @MainActor
    func realOpenReturnsToOverviewCostAndCollapsed() {
        let state = ModernPanelState()
        state.selectedSubscription = .claudeCode
        state.hero = .token
        state.detailsExpanded = true

        state.panelDidOpen()

        #expect(state.selectedSubscription == nil)
        #expect(state.hero == .cost)
        #expect(state.detailsExpanded == false)
    }

    @Test @MainActor
    func refreshScopeFollowsWhatIsOnScreen() {
        let state = ModernPanelState()
        #expect(state.quotaRefreshScope(enabled: []) == nil)
        // A single subscription has no 概览: its detail is the view.
        #expect(state.quotaRefreshScope(enabled: [.cursor]) == .one(.cursor))
        #expect(state.quotaRefreshScope(enabled: [.codex, .claudeCode]) == .all)

        state.selectedSubscription = .claudeCode
        #expect(state.quotaRefreshScope(enabled: [.codex, .claudeCode]) == .one(.claudeCode))
        // A selection whose product was turned off falls back to 概览.
        #expect(state.quotaRefreshScope(enabled: [.codex, .grok]) == .all)
        #expect(state.focusedSubscription(enabled: [.codex, .grok]) == nil)
    }

    // MARK: Height

    @Test func panelFollowsContentUntilTheScreenLimit() {
        #expect(ModernPanelHeight.panel(content: 392, chrome: 124, maxHeight: 900) == 516)
        #expect(ModernPanelHeight.middle(content: 392, chrome: 124, maxHeight: 900) == 392)
        // Expanded past the screen: header and footer stay, the middle scrolls.
        #expect(ModernPanelHeight.panel(content: 912, chrome: 124, maxHeight: 800) == 800)
        #expect(ModernPanelHeight.middle(content: 912, chrome: 124, maxHeight: 800) == 676)
        #expect(ModernPanelHeight.middle(content: 912, chrome: 124, maxHeight: 100) == 0)
    }

    @Test func maxHeightKeepsTheTopUnderTheIcon() {
        let visible = NSRect(x: 0, y: 80, width: 1_440, height: 820)  // Dock below
        let anchor = NSRect(x: 1_300, y: 900, width: 24, height: 23)
        let maxHeight = MenuBarPanelGeometry.maxHeight(
            anchorFrame: anchor, visibleFrame: visible, topGap: 6, bottomInset: 8
        )
        #expect(maxHeight == CGFloat(900 - 6 - 80 - 8))

        // A panel of exactly that height is placed with its top at the
        // usual spot, so a taller content never pushes the top up.
        let point = MenuBarPanelGeometry.topLeftPoint(
            anchorFrame: anchor, panelSize: NSSize(width: 520, height: maxHeight),
            visibleFrame: visible, topGap: 6, edgeInset: 8
        )
        #expect(point.y == 894)
    }

    // MARK: Footer label

    @Test func syncLabelStates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ModernSyncLabel.make(status: .syncing, lastSuccess: nil, now: now) == .syncing)
        #expect(ModernSyncLabel.make(status: .idle, lastSuccess: nil, now: now) == .never)
        #expect(
            ModernSyncLabel.make(status: .idle, lastSuccess: now.addingTimeInterval(-26 * 60), now: now)
                == .synced(number: "26", text: " 分钟前同步")
        )
        #expect(
            ModernSyncLabel.make(status: .success, lastSuccess: now.addingTimeInterval(-10), now: now)
                == .synced(number: nil, text: "刚刚同步")
        )
        let failure = "同步失败: 连不上服务器\nat fetch (node:internal)"
        #expect(
            ModernSyncLabel.make(status: .error(failure), lastSuccess: now, now: now)
                == .failed(reason: "连不上服务器", detail: failure)
        )
        #expect(
            ModernSyncLabel.make(status: .error("同步超时"), lastSuccess: nil, now: now)
                == .failed(reason: "同步超时", detail: "同步超时")
        )
    }

    // MARK: Last successful sync

    @Test @MainActor
    func lastSuccessfulSyncSurvivesARestartAndGoesWithAReset() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test")
        let state = AppState(
            initialConfig: config,
            loadConfig: { config },
            usageFetcher: { _, _, _ in UsageResponse(buckets: [], sessions: nil, hasAnyData: false, names: nil) },
            quotaDefaults: defaults
        )
        state.runSync = { (.success("ok"), nil) }
        #expect(state.lastSuccessfulSyncAt == nil)

        // The success path waits three seconds before going idle; only its
        // first half matters here.
        let sync = Task { await state.triggerSync() }
        defer { sync.cancel() }
        while state.lastSuccessfulSyncAt == nil { await Task.yield() }
        let saved = try #require(state.lastSuccessfulSyncAt)

        let restarted = AppState(initialConfig: config, loadConfig: { config }, quotaDefaults: defaults)
        #expect(restarted.lastSuccessfulSyncAt == saved)

        restarted.applyConfig(nil)  // Settings 「重置配置」
        #expect(restarted.lastSuccessfulSyncAt == nil)
        #expect(AppState(loadConfig: { nil }, quotaDefaults: defaults).lastSuccessfulSyncAt == nil)
    }

    @Test @MainActor
    func upgradeTakesTheLastSuccessFromTheSyncHistory() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let history = SyncHistoryStore(defaults: defaults)
        history.append(SyncRecord(startedAt: started, duration: 4, trigger: .scheduled, result: .success))
        history.append(SyncRecord(startedAt: started.addingTimeInterval(1_800), duration: 2,
                                  trigger: .scheduled, result: .failure, reason: .network))

        let state = AppState(loadConfig: { nil }, quotaDefaults: defaults)
        #expect(state.lastSuccessfulSyncAt == started.addingTimeInterval(4))
        // Saved at once, so ten later failures pushing the record out of the
        // history do not turn it into 「还没同步过」.
        for index in 1...SyncHistoryStore.limit {
            history.append(SyncRecord(startedAt: started.addingTimeInterval(Double(index) * 3_600), duration: 1,
                                      trigger: .scheduled, result: .failure, reason: .network))
        }
        #expect(history.records().allSatisfy { $0.result == .failure })
        #expect(AppState(loadConfig: { nil }, quotaDefaults: defaults).lastSuccessfulSyncAt
            == started.addingTimeInterval(4))
    }

    @Test @MainActor
    func aSyncThatOutlivesItsAccountIsDropped() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var config: VibeUsageConfig? = VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test")
        let state = AppState(
            initialConfig: config,
            loadConfig: { config },
            usageFetcher: { _, _, _ in UsageResponse(buckets: [], sessions: nil, hasAnyData: false, names: nil) },
            quotaDefaults: defaults
        )
        var pending: CheckedContinuation<Void, Never>?
        var runs = 0
        state.runSync = {
            runs += 1
            if runs == 1 { await withCheckedContinuation { pending = $0 } }
            return (.success("ok"), SyncEngine.Outcome(result: .success))
        }

        // Settings 「重置配置」 while the CLI runs.
        let sync = Task { await state.triggerSync() }
        await waitUntil { pending != nil }
        config = nil
        state.applyConfig(nil)
        pending?.resume()
        await sync.value

        #expect(runs == 1)
        #expect(state.lastSuccessfulSyncAt == nil)
        #expect(defaults.object(forKey: AppState.lastSuccessfulSyncKey) == nil)
        #expect(state.syncHistory.records().isEmpty)
        #expect(state.syncStatus == .idle)
        #expect(state.lastSyncTime == nil)
    }

    @Test @MainActor
    func aRelinkDuringASyncSyncsTheNewAccount() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var config: VibeUsageConfig? = VibeUsageConfig(apiKey: "old", apiUrl: "https://example.test")
        let state = AppState(
            initialConfig: config,
            loadConfig: { config },
            usageFetcher: { _, _, _ in UsageResponse(buckets: [], sessions: nil, hasAnyData: false, names: nil) },
            quotaDefaults: defaults
        )
        var pending: CheckedContinuation<Void, Never>?
        var runs = 0
        state.runSync = {
            runs += 1
            if runs == 1 { await withCheckedContinuation { pending = $0 } }
            return (.failure(.timeout), SyncEngine.Outcome(result: .timedOut))
        }

        let sync = Task { await state.triggerSync() }
        await waitUntil { pending != nil }
        config = VibeUsageConfig(apiKey: "new", apiUrl: "https://example.test")
        state.applyConfig(config)
        pending?.resume()
        await sync.value

        // The old account's run is not recorded; the new account's is.
        #expect(runs == 2)
        #expect(state.syncHistory.records().count == 1)
    }

    // MARK: 「同步用量」 and 「刷新额度」 are separate

    @Test @MainActor
    func syncUsageDoesNotReadQuotas() async {
        let fixture = QuotaFixture([.codex, .kimiCode])
        defer { fixture.tearDown() }
        var syncs = 0
        fixture.state.runSync = {
            syncs += 1
            return (.failure(.timeout), nil)
        }

        await fixture.state.triggerSync()

        #expect(syncs == 1)
        #expect(fixture.codexReads == 0)
        #expect(fixture.cliReads.isEmpty)
    }

    @Test @MainActor
    func refreshQuotasNeverSyncsAndReadsTheScope() async {
        let fixture = QuotaFixture([.codex, .kimiCode, .grok])
        defer { fixture.tearDown() }
        var syncs = 0
        fixture.state.runSync = {
            syncs += 1
            return (.failure(.timeout), nil)
        }

        await fixture.state.refreshQuotas(.one(.kimiCode))
        #expect(fixture.codexReads == 0)
        #expect(fixture.cliReads == [[.kimiCode]])

        await fixture.state.refreshQuotas(.all)
        #expect(fixture.codexReads == 1)
        #expect(fixture.cliReads.last.map(Set.init) == [.kimiCode, .grok])
        #expect(syncs == 0)
        #expect(fixture.state.syncStatus == .idle)
    }

    @Test @MainActor
    func openingThePanelUsesTheIntervalNotAForcedRead() async {
        let fixture = QuotaFixture([.codex, .kimiCode])
        defer { fixture.tearDown() }
        fixture.state.modernPanel.selectedSubscription = .kimiCode
        fixture.state.modernPanel.detailsExpanded = true

        await fixture.state.panelWillOpen().value
        #expect(fixture.codexReads == 1)
        #expect(fixture.cliReads.count == 1)
        #expect(fixture.state.modernPanel.selectedSubscription == nil)
        #expect(fixture.state.modernPanel.detailsExpanded == false)

        // Re-opening within the interval reads nothing again.
        fixture.state.rateLimitPanelVisibilityChanged(visible: false)
        await fixture.state.panelWillOpen().value
        #expect(fixture.codexReads == 1)
        #expect(fixture.cliReads.count == 1)
    }

    @Test @MainActor
    func refreshSpinnerFollowsTheScope() {
        let fixture = QuotaFixture([.codex, .kimiCode])
        defer { fixture.tearDown() }
        #expect(fixture.state.isRefreshingQuotas(.all) == false)
        fixture.state.cliQuotaRefreshingProviders = [.kimiCode]
        #expect(fixture.state.isRefreshingQuotas(.all))
        #expect(fixture.state.isRefreshingQuotas(.one(.kimiCode)))
        #expect(fixture.state.isRefreshingQuotas(.one(.codex)) == false)
    }

    @Test @MainActor
    func aClickWhileTheScopeIsReadingSendsNothingMore() async {
        let fixture = QuotaFixture([.codex, .kimiCode])
        defer { fixture.tearDown() }
        fixture.holdCLI = true

        // 概览: Codex answers at once, Kimi is still reading.
        let first = Task { await fixture.state.refreshQuotas(.all) }
        await waitUntil { fixture.hasHeldCLIRead && fixture.codexReads == 1 && !fixture.state.isCodexRateLimitRefreshing }
        #expect(fixture.state.isRefreshingQuotas(.all))

        // Not awaited before checking: a click that did read would wait for
        // the held Kimi read.
        let again = Task { await fixture.state.refreshQuotas(.all) }
        let kimiAgain = Task { await fixture.state.refreshQuotas(.one(.kimiCode)) }
        for _ in 0..<1_000 { await Task.yield() }
        #expect(fixture.codexReads == 1)
        #expect(fixture.cliReads.count == 1)

        // Another subscription's own scope is not busy.
        await fixture.state.refreshQuotas(.one(.codex))
        #expect(fixture.codexReads == 2)

        fixture.releaseCLI()
        await first.value
        await again.value
        await kimiAgain.value
        #expect(fixture.codexReads == 2)
        #expect(fixture.cliReads.count == 1)

        // Once everything answered, a click reads again.
        await fixture.state.refreshQuotas(.all)
        #expect(fixture.codexReads == 3)
        #expect(fixture.cliReads.count == 2)
    }

    // MARK: Fonts

    @Test @MainActor
    func bundledFontsRegisterFromTheResourceBundle() throws {
        let bundle = try #require(PanelTestResources.bundle)
        #expect(AppFonts.register(from: bundle) == AppFonts.fileNames)
        // Registering again (the app and a test in one process) is harmless.
        #expect(AppFonts.register(from: bundle) == AppFonts.fileNames)
        for name in AppFonts.fileNames {
            #expect(NSFont(name: name, size: 13)?.fontName == name)
        }
    }

    // MARK: Helpers

    /// Yields until `condition` holds (bounded, so a broken test fails
    /// instead of hanging).
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100_000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "ModernPanelTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

/// An AppState with the given products selected, isolated preferences and a
/// quota coordinator whose readers only count their calls.
@MainActor
private final class QuotaFixture {
    let state: AppState
    let defaults: UserDefaults
    let suite: String
    var codexReads = 0
    var cliReads: [[ProviderRateLimit.Provider]] = []
    /// While set, CLI reads wait until `releaseCLI()`: a slow provider.
    var holdCLI = false
    private var heldCLI: [CheckedContinuation<Void, Never>] = []
    var hasHeldCLIRead: Bool { !heldCLI.isEmpty }

    func releaseCLI() {
        holdCLI = false
        heldCLI.forEach { $0.resume() }
        heldCLI.removeAll()
    }

    init(_ providers: [ProviderRateLimit.Provider]) {
        suite = "ModernPanelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(providers.map(\.rawValue), forKey: QuotaSelectionPreferences.selectedIDsKey)
        state = AppState(
            loadConfig: { nil },
            quotaDefaults: defaults,
            zCodeAPIKeyStore: NoZCodeKey(),
            quotaProductDiscoverer: {
                QuotaProductRegistry.catalog.map { QuotaProduct(provider: $0.0, availability: $0.1, isDetected: true) }
            }
        )
        state.makeRateLimitCoordinator = { [unowned self] appState in
            RateLimitCoordinator(
                appState: appState,
                fetchCodexLive: {
                    self.codexReads += 1
                    return ProviderRateLimit(provider: .codex, status: .noData, fetchedAt: Date())
                },
                loadCodexCache: { nil },
                readCodexFallback: { ProviderRateLimit(provider: .codex, status: .noData, fetchedAt: nil) },
                fetchCLIQuotas: { providers, _, _ in
                    self.cliReads.append(providers)
                    if self.holdCLI { await withCheckedContinuation { self.heldCLI.append($0) } }
                    return providers.map { ProviderRateLimit(provider: $0, status: .noData, fetchedAt: Date()) }
                }
            )
        }
        state.initializeQuotaProducts()
        state.startRateLimitCoordinator()
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class NoZCodeKey: ZCodeAPIKeyStoring {
    func load(for region: ZCodeQuotaRegion) throws -> String? { nil }
    func store(_ value: String?, for region: ZCodeQuotaRegion) throws {}
}

/// The app's SwiftPM resource bundle as a test process finds it: next to the
/// test bundle in the build products.
enum PanelTestResources {
    private final class Marker {}

    static var bundle: Bundle? {
        let name = "VibeUsage_VibeUsage.bundle"
        let candidates = [
            Bundle(for: Marker.self).bundleURL.deletingLastPathComponent(),
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
        ]
        return candidates.lazy.compactMap { $0.flatMap { Bundle(url: $0.appendingPathComponent(name)) } }.first
    }
}

/// `MenuBarController` lays the panel out once before showing it and reads
/// the height the view reported in that pass. Off-screen, never ordered in.
struct ModernPanelHeightReportTests {
    @Test @MainActor
    func oneLayoutPassReportsTheCurrentContentsHeight() throws {
        _ = NSApplication.shared
        let fixture = PanelFixture(PanelScene(id: "report", title: "高度"))
        defer { fixture.tearDown() }
        let layout = ModernPanelLayout()
        var reports: [CGFloat] = []
        let root = PanelRootView(layout: layout) { reports.append($0) }
            .environment(fixture.state)
            .environmentObject(fixture.updater)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.minSize, .maxSize]
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 520, height: 620),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host

        host.layoutSubtreeIfNeeded()
        // Header 40 + 概览 row 46 + cards 208 + 8 + 176 + footer 38 (131a).
        #expect(reports.last == 516)

        fixture.state.modernPanel.detailsExpanded = true
        host.layoutSubtreeIfNeeded()
        #expect(reports.last == 1_036)

        layout.maxHeight = 700  // a short screen: the middle scrolls
        host.layoutSubtreeIfNeeded()
        #expect(reports.last == 700)

        fixture.state.modernPanel.panelDidOpen()
        host.layoutSubtreeIfNeeded()
        #expect(reports.last == 516)
    }
}

/// The window side of "the panel follows its content": an off-screen panel
/// (never ordered in), resized while its content layer has the open
/// animation's top-right anchor.
struct PopoverPanelResizeTests {
    @Test @MainActor
    func resizingKeepsTheTopEdgeAndTheContentLayerInPlace() throws {
        _ = NSApplication.shared
        let panel = PopoverPanel(
            contentRect: NSRect(x: 800, y: 300, width: 520, height: 620),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        let content = try #require(panel.contentView)
        content.wantsLayer = true
        let layer = try #require(content.layer)
        let top = panel.frame.maxY
        PopoverPanelResize.setAnchorPoint(CGPoint(x: 1, y: 1), for: layer)

        for height in [CGFloat(516), 1_036, 400] {
            PopoverPanelResize.setHeight(height, width: 520, of: panel)
            #expect(panel.frame.maxY == top)
            #expect(panel.frame.height == height)
            #expect(layer.anchorPoint == CGPoint(x: 1, y: 1))
            #expect(layer.frame == content.frame)
        }
    }
}
