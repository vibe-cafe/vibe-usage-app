import Foundation
import Testing
@testable import VibeUsage

/// The Settings sidebar is generated from two lists: `SettingsCategory` (the
/// category rows) and the quota product catalog (the 提供商 rows and their
/// pages). These tests pin that nothing is declared a second time by hand and
/// that dragging a row goes through the panel's own reorder.
@MainActor
struct SettingsLayoutTests {
    private final class MemoryZCodeKeyStore: ZCodeAPIKeyStoring {
        func load(for region: ZCodeQuotaRegion) throws -> String? { nil }
        func store(_ value: String?, for region: ZCodeQuotaRegion) throws {}
    }

    private func appState(selected: [String]) -> (AppState, UserDefaults, String) {
        let suite = "SettingsLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(selected, forKey: QuotaSelectionPreferences.selectedIDsKey)
        let state = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: MemoryZCodeKeyStore(),
            quotaProductDiscoverer: {
                QuotaProductRegistry.catalog.map { QuotaProduct(provider: $0.0, availability: $0.1, isDetected: false) }
            }
        )
        state.initializeQuotaProducts()
        return (state, defaults, suite)
    }

    @Test func categoriesComeFromTheManifestWithDebugOnlyInTestBuilds() {
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        #expect(SettingsSidebar.categories.map(\.title) == ["通用", "账号与同步", "数据来源", "关于与诊断", "调试"])
        #else
        #expect(SettingsSidebar.categories.map(\.title) == ["通用", "账号与同步", "数据来源", "关于与诊断"])
        #endif
        #expect(SettingsSidebar.categories == SettingsCategory.allCases.filter(\.isAvailable))
    }

    @Test func providerRowsAreTheCatalogInThePanelsOrder() {
        let (state, defaults, suite) = appState(selected: ["cursor", "codex"])
        defer { defaults.removePersistentDomain(forName: suite) }

        let rows = SettingsSidebar.providers(state)
        #expect(rows == state.quotaTabOrder)
        #expect(rows.count == QuotaProductRegistry.catalog.count)
        #expect(Set(rows) == Set(QuotaProductRegistry.catalog.map(\.0)))
        // Enabled products first, like the panel's tab strip.
        #expect(Array(rows.prefix(2)) == [.codex, .cursor])
        #expect(SettingsSidebar.enabledSummary(state) == "2 个已开启")
    }

    @Test func destinationsRoundTripTheLaunchHookAndNameTheWindow() {
        #expect(SettingsDestination(rawValue: "general") == .category(.general))
        #expect(SettingsDestination(rawValue: "zcode") == .provider(.zCode))
        #expect(SettingsDestination(rawValue: "nope") == nil)
        #expect(SettingsDestination.category(.about).title == "关于与诊断")
        #expect(SettingsDestination.provider(.opencodeGo).title == "OpenCode Go")
    }

    @Test func onMoveOffsetsMapToThePanelsBeforeTarget() {
        let order: [ProviderRateLimit.Provider] = [.codex, .claudeCode, .cursor]
        // Dragging the last row to the top lands it in front of the first.
        #expect(SettingsSidebar.moveRequest(order: order, from: [2], to: 0).map { [$0.provider, $0.before] } == [.cursor, .codex])
        // An offset past the end means "after the last row".
        let toEnd = SettingsSidebar.moveRequest(order: order, from: [0], to: 3)
        #expect(toEnd?.provider == .codex)
        #expect(toEnd?.before == nil)
        #expect(SettingsSidebar.moveRequest(order: order, from: [5], to: 0) == nil)
    }

    @Test func draggingARowPersistsThroughTheSharedOrderKey() {
        let (state, defaults, suite) = appState(selected: ["codex", "claude-code", "cursor"])
        defer { defaults.removePersistentDomain(forName: suite) }

        let rows = SettingsSidebar.providers(state)
        let move = SettingsSidebar.moveRequest(order: rows, from: [rows.firstIndex(of: .cursor)!], to: 0)!
        state.moveQuotaProduct(move.provider, before: move.before)

        #expect(Array(SettingsSidebar.providers(state).prefix(3)) == [.cursor, .codex, .claudeCode])
        let stored = defaults.array(forKey: QuotaSelectionPreferences.orderKey) as? [String]
        #expect(Array((stored ?? []).prefix(3)) == ["cursor", "codex", "claude-code"])
    }

    @Test func onlyZCodeOpensAConfigurationPage() {
        for provider in QuotaProductRegistry.catalog.map(\.0) {
            let expected: QuotaSettingsCatalog.Page = provider == .zCode ? .zCodeAPIKey : .standard
            #expect(QuotaSettingsCatalog.page(for: provider) == expected)
        }
    }

    @Test func claudeNamesItsSourceOnlyWhenDesktopSuppliesTheCLI() {
        #expect(QuotaSettingsCatalog.sourceNote(for: .claudeCode, claudeUsesDesktopBundledCLI: true) == "Claude Desktop")
        #expect(QuotaSettingsCatalog.sourceNote(for: .claudeCode, claudeUsesDesktopBundledCLI: false) == nil)
    }
}
