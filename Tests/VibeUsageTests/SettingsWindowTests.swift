import Foundation
import SwiftUI
import Testing
@testable import VibeUsage

/// The Settings window's rules that do not need a window: which page opens,
/// what the 订阅配额 status column and the 同步 row say, where a dragged row
/// lands, and how ZCode's key block behaves.
struct SettingsWindowTests {
    private final class MemoryZCodeKeyStore: ZCodeAPIKeyStoring {
        var values: [ZCodeQuotaRegion: String] = [:]
        func load(for region: ZCodeQuotaRegion) throws -> String? { values[region] }
        func store(_ value: String?, for region: ZCodeQuotaRegion) throws { values[region] = value }
    }

    private func defaults() -> (UserDefaults, String) {
        let suite = "SettingsWindowTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func products(detected: Set<ProviderRateLimit.Provider>) -> [QuotaProduct] {
        QuotaProductRegistry.catalog.map { provider, availability in
            QuotaProduct(provider: provider, availability: availability, isDetected: detected.contains(provider))
        }
    }

    @Test
    func quotaWarningDescribesTheSettledRead() {
        let product = QuotaProduct(provider: .opencodeGo, availability: .ready, isDetected: true)
        func status(
            _ status: ProviderRateLimit.Status,
            emptyReason: ProviderRateLimit.EmptyReason? = nil,
            failure: ProviderRateLimit.LiveFailure? = nil
        ) -> (SettingsStatusKind, String) {
            SettingsQuotaStatus.status(for: product, zCodeKeyConfigured: false, warningSnapshot: .init(
                provider: product.provider, status: status, fetchedAt: Date(), emptyReason: emptyReason, liveFailure: failure
            ))
        }

        #expect(status(.unauthorized) == (.warning, "需登录"))
        #expect(status(.noData, emptyReason: .notEntitled, failure: .credentialsRejected) == (.warning, "未订阅"))
        #expect(status(.noData, failure: .credentialsExpired) == (.warning, "需打开"))
        #expect(status(.noData, emptyReason: .sessionWithoutPlanLimits) == (.warning, "不适用"))
        #expect(status(.noData, emptyReason: .nonessentialTrafficDisabled) == (.warning, "已禁止"))
        #expect(status(.noData, emptyReason: .limitReached) == (.warning, "已用满"))
        #expect(status(.noData, emptyReason: .noWindow) == (.warning, "无窗口"))
        for state in [ProviderRateLimit.Status.noData, .retryableError] {
            #expect(status(state, failure: .credentialsNotFound) == (.warning, "需登录"))
            #expect(status(state, failure: .credentialsRejected) == (.warning, "已失效"))
        }
        #expect(SettingsQuotaStatus.status(for: product, zCodeKeyConfigured: false,
            warningSnapshot: .init(provider: .opencodeGo, status: .noData)) == (.warning, "未读取"))
        #expect(status(.noData) == (.warning, "无数据"))
        #expect(status(.noData, failure: .endpointUnreachable) == (.warning, "连不上"))
        #expect(status(.retryableError, failure: .endpointTimedOut) == (.warning, "超时"))
        #expect(status(.error("fixture")) == (.error, "出错"))
        #expect(status(.disabled) == (.warning, "未启用"))

        // Other native providers keep their own words.
        let codex = QuotaProduct(provider: .codex, availability: .ready, isDetected: true)
        #expect(SettingsQuotaStatus.status(for: codex, zCodeKeyConfigured: false, warningSnapshot: .init(
            provider: .codex, status: .noData, liveFailure: .credentialsNotFound
        )) == (.warning, "需登录"))
    }

    // MARK: - Navigation

    @Test @MainActor
    func firstOpenShowsGeneralAndLaterOpensReturnToTheLastPage() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsNavigation(defaults: defaults)
        #expect(first.page == .general)

        first.page = .directories
        #expect(defaults.string(forKey: SettingsNavigation.lastPageKey) == "directories")
        #expect(SettingsNavigation(defaults: defaults).page == .directories)
    }

    @Test @MainActor
    func unknownStoredPageFallsBackToGeneral() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("someFuturePage", forKey: SettingsNavigation.lastPageKey)

        #expect(SettingsNavigation(defaults: defaults).page == .general)
    }

    @Test @MainActor
    func popoverSettingsKeepsTheLastPage() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SettingsNavigation(defaults: defaults)
        navigation.page = .about

        navigation.open(.lastPage, zCodeKeyConfigured: false)

        #expect(navigation.page == .about)
        #expect(navigation.focusedProvider == nil)
    }

    @Test @MainActor
    func panelGearOpensQuotasWithoutFocusingARow() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SettingsNavigation(defaults: defaults)

        navigation.open(.quotas(focus: nil), zCodeKeyConfigured: false)

        #expect(navigation.page == .quotas)
        #expect(navigation.focusedProvider == nil)
        #expect(navigation.expandedProviders.isEmpty)
    }

    /// A grey ZCode tab without a key opens straight into ZCode's key block;
    /// with a key, or for any other product, the row only flashes.
    @Test @MainActor
    func greyTabFocusesItsRowAndOpensZCodeOnlyWhileTheKeyIsMissing() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SettingsNavigation(defaults: defaults)

        navigation.open(.quotas(focus: .zCode), zCodeKeyConfigured: false)
        #expect(navigation.page == .quotas)
        #expect(navigation.focusedProvider == .zCode)
        #expect(navigation.expandedProviders == [.zCode])
        let firstRequest = navigation.focusRequest

        navigation.resetTransientState()
        navigation.open(.quotas(focus: .zCode), zCodeKeyConfigured: true)
        #expect(navigation.expandedProviders.isEmpty)
        #expect(navigation.focusRequest != firstRequest)

        navigation.open(.quotas(focus: .kimiCode), zCodeKeyConfigured: false)
        #expect(navigation.focusedProvider == .kimiCode)
        #expect(navigation.expandedProviders.isEmpty)
    }

    @Test
    func onlyZCodeWithoutAKeyOpensOnArrival() {
        #expect(SettingsNavigation.opensConfiguration(on: .zCode, zCodeKeyConfigured: false))
        #expect(!SettingsNavigation.opensConfiguration(on: .zCode, zCodeKeyConfigured: true))
        for provider in ProviderRateLimit.Provider.allCases where provider != .zCode {
            #expect(!SettingsNavigation.opensConfiguration(on: provider, zCodeKeyConfigured: false))
        }
    }

    // MARK: - 订阅配额 status column

    @Test
    func unauthorizedZCodeStatusDistinguishesMissingAndInvalidKeys() {
        let product = QuotaProduct(provider: .zCode, availability: .ready, isDetected: true)
        let snapshot = ProviderRateLimit(provider: .zCode, status: .unauthorized)

        #expect(SettingsQuotaStatus.status(for: product, zCodeKeyConfigured: false, warningSnapshot: snapshot)
            == (.warning, "需 Key"))
        #expect(SettingsQuotaStatus.status(for: product, zCodeKeyConfigured: true, warningSnapshot: snapshot)
            == (.warning, "Key 无效"))
    }

    @Test
    func statusColumnNamesWhatIsMissingBeforeLocalDetection() {
        let zCode = { (detected: Bool) in QuotaProduct(provider: .zCode, availability: .ready, isDetected: detected) }

        #expect(SettingsQuotaStatus.status(for: zCode(true), zCodeKeyConfigured: false) == (.warning, "需 Key"))
        #expect(SettingsQuotaStatus.status(for: zCode(false), zCodeKeyConfigured: false) == (.warning, "需 Key"))
        #expect(SettingsQuotaStatus.status(for: zCode(true), zCodeKeyConfigured: true) == (.ok, "已检测"))
        #expect(SettingsQuotaStatus.status(for: zCode(false), zCodeKeyConfigured: true) == (.none, "未检测到"))

        let codex = QuotaProduct(provider: .codex, availability: .ready, isDetected: true)
        let grok = QuotaProduct(provider: .grok, availability: .ready, isDetected: false)
        #expect(SettingsQuotaStatus.status(for: codex, zCodeKeyConfigured: false) == (.ok, "已检测"))
        #expect(SettingsQuotaStatus.status(for: grok, zCodeKeyConfigured: false) == (.none, "未检测到"))

        let pending = QuotaProduct(provider: .cursor, availability: .pendingProtocol, isDetected: true)
        #expect(SettingsQuotaStatus.status(for: pending, zCodeKeyConfigured: false) == (.ok, "已检测 · 待接入"))
    }

    // MARK: - 同步 row

    @Test
    func syncLineFollowsTheSyncStatus() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let threeMinutesAgo = now.addingTimeInterval(-185)

        #expect(SettingsSyncSummary.line(status: .idle, isConfigured: false, lastSync: nil, now: now)
            == .init(kind: nil, text: "—"))
        #expect(SettingsSyncSummary.line(status: .idle, isConfigured: true, lastSync: threeMinutesAgo, now: now)
            == .init(kind: .ok, text: "正常 · 3 分钟前"))
        #expect(SettingsSyncSummary.line(status: .success, isConfigured: true, lastSync: nil, now: now)
            == .init(kind: .ok, text: "正常"))
        #expect(SettingsSyncSummary.line(status: .syncing, isConfigured: true, lastSync: threeMinutesAgo, now: now)
            == .init(kind: nil, text: "同步中…", isSpinning: true))
        #expect(SettingsSyncSummary.line(status: .error("API Key 无效，请重新配置"), isConfigured: true, lastSync: nil, now: now)
            == .init(kind: .error, text: "API Key 无效，请重新配置"))
    }

    @Test
    func sidebarShowsARedDotOnlyAfterAFailure() {
        #expect(SettingsSyncSummary.sidebarDot(status: .idle, isConfigured: true) == nil)
        #expect(SettingsSyncSummary.sidebarDot(status: .success, isConfigured: true) == nil)
        #expect(SettingsSyncSummary.sidebarDot(status: .syncing, isConfigured: true) == nil)
        #expect(SettingsSyncSummary.sidebarDot(status: .error("x"), isConfigured: true) == .error)
    }

    /// 「重置配置」 leaves the last failure in memory; the dot follows the
    /// 同步 row, which shows 「—」 once nothing is linked.
    @Test @MainActor
    func resetClearsTheSidebarDotEvenAfterAFailure() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(quotaDefaults: defaults, zCodeAPIKeyStore: MemoryZCodeKeyStore())
        appState.isConfigured = true
        appState.syncStatus = .error("API Key 无效，请重新配置")
        #expect(SettingsSyncSummary.sidebarDot(status: appState.syncStatus, isConfigured: appState.isConfigured) == .error)

        appState.isConfigured = false  // what resetConfig() leaves behind
        #expect(SettingsSyncSummary.sidebarDot(status: appState.syncStatus, isConfigured: appState.isConfigured) == nil)
        #expect(SettingsSyncSummary.line(status: appState.syncStatus, isConfigured: appState.isConfigured, lastSync: nil)
            == .init(kind: nil, text: "—"))
    }

    /// The store keeps the newest first; the bars read oldest to newest.
    @Test
    func syncBarsReadOldestToNewest() {
        func record(_ result: SyncRecord.Result) -> SyncRecord {
            SyncRecord(startedAt: Date(), duration: 1, trigger: .scheduled, result: result)
        }
        let newestFirst = [record(.failure), record(.success), record(.timedOut)]
        #expect(SettingsSyncSummary.bars(from: newestFirst) == [false, true, false])
        #expect(SettingsSyncSummary.bars(from: Array(repeating: record(.success), count: 14)).count == 10)
        #expect(SettingsSyncSummary.bars(from: []).isEmpty)
    }

    // MARK: - Drag to reorder

    @Test
    func dropStaysInsideTheDraggedGroup() {
        let on: [ProviderRateLimit.Provider] = [.codex, .claudeCode, .cursor]
        let off: [ProviderRateLimit.Provider] = [.kimiCode, .zCode, .grok]

        #expect(QuotaReorder.target(dragged: .cursor, row: .claudeCode, dropAfter: false, enabled: on, disabled: off)
            == .before(.claudeCode))
        #expect(QuotaReorder.target(dragged: .codex, row: .claudeCode, dropAfter: true, enabled: on, disabled: off)
            == .before(.cursor))
        #expect(QuotaReorder.target(dragged: .codex, row: .cursor, dropAfter: true, enabled: on, disabled: off)
            == .before(nil))
        #expect(QuotaReorder.target(dragged: .codex, row: .kimiCode, dropAfter: false, enabled: on, disabled: off)
            == .reject)
        #expect(QuotaReorder.target(dragged: .grok, row: .zCode, dropAfter: false, enabled: on, disabled: off)
            == .before(.zCode))
        #expect(QuotaReorder.target(dragged: nil, row: .zCode, dropAfter: false, enabled: on, disabled: off)
            == .reject)
    }

    /// A drop in Settings goes through the panel's own `moveQuotaProduct`, so
    /// both read the same stored order afterwards.
    @Test @MainActor
    func settingsDropReordersThePanelsStoredOrder() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(["codex", "claude-code", "cursor"], forKey: QuotaSelectionPreferences.selectedIDsKey)
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: MemoryZCodeKeyStore(),
            quotaProductDiscoverer: { self.products(detected: []) }
        )
        appState.initializeQuotaProducts()
        let enabled = appState.quotaCardProviders
        let disabled = appState.quotaTabOrder.filter { !appState.isQuotaProviderSelected($0) }
        #expect(enabled == [.codex, .claudeCode, .cursor])

        // Cursor onto the top half of Claude.
        guard case .before(let target) = QuotaReorder.target(
            dragged: .cursor, row: .claudeCode, dropAfter: false, enabled: enabled, disabled: disabled
        ) else {
            Issue.record("expected a valid drop")
            return
        }
        appState.moveQuotaProduct(.cursor, before: target)

        #expect(appState.quotaCardProviders == [.codex, .cursor, .claudeCode])
        let stored = defaults.stringArray(forKey: QuotaSelectionPreferences.orderKey) ?? []
        #expect(Array(stored.prefix(3)) == ["codex", "cursor", "claude-code"])
    }

    // MARK: - 额外 Codex Home

    @Test
    func codexHomeSaveIsDimmedOnlyWhenThereIsNothingToSaveOrRemove() {
        #expect(!CodexHomeDraft.canSave(draft: "", saved: ""))
        #expect(!CodexHomeDraft.canSave(draft: "   ", saved: ""))
        #expect(CodexHomeDraft.canSave(draft: "~/Work/codex", saved: ""))
        #expect(CodexHomeDraft.canSave(draft: "~/Work/codex", saved: "~/Work/codex"))
        // Cleared with the field's ×: saving removes the saved path.
        #expect(CodexHomeDraft.canSave(draft: "", saved: "~/Work/codex"))
    }

    // MARK: - ZCode key block

    @Test @MainActor
    func savingAZCodeKeyNeverTurnsTheSwitchOn() async {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(["codex"], forKey: QuotaSelectionPreferences.selectedIDsKey)
        let store = MemoryZCodeKeyStore()
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: store,
            quotaProductDiscoverer: { self.products(detected: [.zCode]) }
        )
        appState.initializeQuotaProducts()
        let model = SettingsModel(appState: appState)

        #expect(!model.showsSavedZCodeKey)
        #expect(!model.canSaveZCodeAPIKey)
        model.zCodeAPIKeyDraft = "  fixture-key  "
        #expect(model.canSaveZCodeAPIKey)

        await model.saveZCodeAPIKey()

        #expect(store.values[.bigModel] == "fixture-key")
        #expect(model.showsSavedZCodeKey)
        #expect(model.zCodeAPIKeyDraft.isEmpty)
        #expect(!appState.isQuotaProviderSelected(.zCode))
    }

    @Test @MainActor
    func replacingShowsTheFieldAgainAndRemovingTurnsTheSwitchOff() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(["codex", "zcode"], forKey: QuotaSelectionPreferences.selectedIDsKey)
        let store = MemoryZCodeKeyStore()
        store.values[.bigModel] = "fixture-key"
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: store,
            quotaProductDiscoverer: { self.products(detected: [.zCode]) }
        )
        appState.initializeQuotaProducts()
        let model = SettingsModel(appState: appState)
        #expect(appState.isQuotaProviderSelected(.zCode))
        #expect(model.showsSavedZCodeKey)

        model.beginReplacingZCodeAPIKey()
        #expect(!model.showsSavedZCodeKey)
        model.cancelReplacingZCodeAPIKey()
        #expect(model.showsSavedZCodeKey)

        model.removeZCodeAPIKey()
        #expect(store.values[.bigModel] == nil)
        #expect(!model.showsSavedZCodeKey)
        #expect(!appState.isQuotaProviderSelected(.zCode))
    }

    // MARK: - Monochrome marks

    @Test
    func svgPathParserReadsTheCompactSyntaxTheMarksUse() {
        // Implicit lineto after moveto, closepath.
        let square = SVGPathParser.path(from: "M0 0 10 0 10 10z")
        #expect(square.boundingRect == CGRect(x: 0, y: 0, width: 10, height: 10))

        // Numbers without separators, relative commands.
        let compact = SVGPathParser.path(from: "M.5.5l1-1")
        #expect(compact.currentPoint == CGPoint(x: 1.5, y: -0.5))

        // Arc flags written as single digits with no separator after them.
        let arc = SVGPathParser.path(from: "M0 0a1 1 0 110 2")
        let end = arc.currentPoint ?? .zero
        #expect(abs(end.x) < 0.0001 && abs(end.y - 2) < 0.0001)
        #expect(abs(arc.boundingRect.width - 1) < 0.01)

        // H / V, exponent notation.
        let hv = SVGPathParser.path(from: "M1e1 0H20V5h-5v1")
        #expect(hv.currentPoint == CGPoint(x: 15, y: 6))
    }

    @Test
    func unreadablePathDataStopsInsteadOfCrashing() {
        let path = SVGPathParser.path(from: "M0 0L5 5 X 9 9")
        #expect(path.currentPoint == CGPoint(x: 5, y: 5))
        #expect(SVGPathParser.path(from: "").isEmpty)
        #expect(SVGPathParser.path(from: "12 34").isEmpty)
    }

    @Test
    func everyProviderHasAMarkInsideItsViewBox() {
        for provider in ProviderRateLimit.Provider.allCases {
            let bounds = ProviderGlyphShape.unitPath(for: provider).boundingRect
            #expect(!bounds.isEmpty, "\(provider) has no mark")
            #expect(bounds.minX >= -0.01 && bounds.minY >= -0.01, "\(provider) \(bounds)")
            #expect(bounds.maxX <= 24.01 && bounds.maxY <= 24.01, "\(provider) \(bounds)")
            #expect(max(bounds.width, bounds.height) > 16, "\(provider) \(bounds)")
        }
    }
}

/// The Settings 通用 preview and the status item share one rule for what the
/// menu bar shows.
struct MenuBarLabelLinesTests {
    private func lines(configured: Bool = true, usage: Bool = true, cost: Bool, tokens: Bool) -> [String] {
        MenuBarLabel.lines(
            isConfigured: configured, hasUsage: usage, showCost: cost, showTokens: tokens,
            cost: { 230.2 }, tokens: { 364_100_000 }
        )
    }

    @Test
    func iconOnlyUntilThereIsUsageToShow() {
        #expect(lines(usage: false, cost: true, tokens: true).isEmpty)
        #expect(lines(configured: false, cost: true, tokens: true).isEmpty)
        #expect(lines(cost: false, tokens: false).isEmpty)
    }

    @Test
    func eachSwitchAddsOneLineCostFirst() {
        let cost = Formatters.formatCost(230.2)
        let tokens = Formatters.formatNumber(364_100_000)
        #expect(lines(cost: true, tokens: false) == [cost])
        #expect(lines(cost: false, tokens: true) == [tokens])
        #expect(lines(cost: true, tokens: true) == [cost, tokens])
    }

    @Test
    func valuesAreNotComputedForSwitchedOffLines() {
        var costRead = false
        var tokensRead = false
        _ = MenuBarLabel.lines(
            isConfigured: true, hasUsage: true, showCost: false, showTokens: false,
            cost: { costRead = true; return 0 }, tokens: { tokensRead = true; return 0 }
        )
        #expect(!costRead && !tokensRead)
    }
}

/// The 关于 page's three links.
struct SettingsLinksTests {
    @Test
    func aboutPageLinksPointAtTheSiteAndBothRepositories() {
        #expect(UsageServer(AppConfig.productionApiUrl).siteURL?.absoluteString == "https://vibefriends.com")
        #expect(SettingsLinks.cliRepository.absoluteString == "https://github.com/vibe-cafe/vibe-usage")
        #expect(SettingsLinks.appRepository.absoluteString == "https://github.com/vibe-cafe/vibe-usage-app")
        for url in [SettingsLinks.cliRepository, SettingsLinks.appRepository] {
            #expect(url.scheme == "https")
        }
    }

    @Test
    func gitHubMarkFillsItsBox() {
        let bounds = GitHubMark().path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).boundingRect
        #expect(bounds.width > 23 && bounds.height > 23)
        #expect(bounds.minX >= -0.01 && bounds.maxX <= 24.01 && bounds.maxY <= 24.01)
    }
}
