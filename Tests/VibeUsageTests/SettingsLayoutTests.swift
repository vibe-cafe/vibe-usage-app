import AppKit
import Testing
@testable import VibeUsage

/// The Settings window is generated from two lists: `SettingsTab` (toolbar
/// tabs) and the quota product catalog (the 订阅配额 list and its pages).
/// These tests pin that nothing is declared a second time by hand.
@MainActor
struct SettingsLayoutTests {
    private func catalogProducts() -> [QuotaProduct] {
        QuotaProductRegistry.catalog.map { provider, availability in
            QuotaProduct(provider: provider, availability: availability, isDetected: false)
        }
    }

    @Test func manifestListsTheFiveCategoriesInToolbarOrder() {
        #expect(SettingsTab.allCases.map(\.title) == ["通用", "账号与同步", "订阅配额", "数据来源", "关于与诊断"])
        #expect(Set(SettingsTab.allCases.map(\.id)).count == SettingsTab.allCases.count)
    }

    @Test func toolbarTabsAreGeneratedFromTheManifest() {
        let items = SettingsWindowController.makeTabViewItems { _ in NSViewController() }

        #expect(items.count == SettingsTab.allCases.count)
        #expect(items.compactMap { $0.identifier as? String } == SettingsTab.allCases.map(\.rawValue))
        #expect(items.map(\.label) == SettingsTab.allCases.map(\.title))
        // The selected page's title becomes the window title.
        #expect(items.map { $0.viewController?.title } == SettingsTab.allCases.map(\.title))
        #expect(items.allSatisfy { $0.image != nil })
    }

    @Test func everyCatalogProductHasExactlyOneRowInCatalogOrderWithZCodeLast() {
        let catalog = QuotaProductRegistry.catalog.map(\.0)
        let rows = QuotaSettingsCatalog.listOrder(catalogProducts()).map(\.provider)

        #expect(rows.count == catalog.count)
        #expect(Set(rows) == Set(catalog))
        #expect(rows.last == .zCode)
        #expect(Array(rows.dropLast()) == catalog.filter { $0 != .zCode })
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

    @Test func rowStatusShortensOnlyTheZCodeForm() {
        let zCode = QuotaProduct(provider: .zCode, availability: .ready, isDetected: true)
        let kimi = QuotaProduct(provider: .kimiCode, availability: .ready, isDetected: true)

        #expect(QuotaSettingsCatalog.rowStatus(for: zCode, statusText: "已检测 · Z.ai（海外） 已配置") == "已配置")
        #expect(QuotaSettingsCatalog.rowStatus(for: zCode, statusText: "需配置 BigModel API Key") == "待配置")
        #expect(QuotaSettingsCatalog.rowStatus(for: zCode, statusText: "未检测到") == "待配置")
        #expect(QuotaSettingsCatalog.rowStatus(for: kimi, statusText: "未检测到") == "未检测到")
    }
}
