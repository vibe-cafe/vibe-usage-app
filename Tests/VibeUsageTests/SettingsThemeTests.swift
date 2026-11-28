import Foundation
import SwiftUI
import Testing
@testable import VibeUsage

/// The Settings window's two themes (#108): classic keeps the 2026-11-20
/// metrics, modern lines up with the panel, and the rules the modern look
/// adds (number runs, menu placement) hold without rendering.
struct SettingsThemeTests {
    @Test
    func eachStyleGetsItsOwnTheme() {
        #expect(SettingsTheme.of(.classic).style == .classic)
        #expect(SettingsTheme.of(.modern).style == .modern)
    }

    @Test
    func classicKeepsTheFinalizedLayout() {
        let theme = SettingsTheme.classic
        #expect(theme.sidebarWidth == 168)
        #expect(theme.windowButtonCenter == CGPoint(x: 22, y: 24))
        #expect(theme.pageTopInset == 20)
        #expect(theme.pageHorizontalInset == 22)
        #expect(theme.rowHeight == 44)
        #expect(theme.tallRowHeight == 52)
        #expect(theme.rowLeading == 14)
        #expect(theme.cardPadding == EdgeInsets())
    }

    /// The modern page column is a panel's width (520) and its text sits on
    /// the panel's 28 pt line; rows are 37 pt (36 + rule), the design's
    /// overview line (the panel's overview has spaced its rows since
    /// 2026-11-28; Settings kept 37).
    @Test
    func modernLinesUpWithThePanel() {
        let theme = SettingsTheme.modern
        #expect(SettingsTheme.windowSize.width == 700)
        #expect(SettingsTheme.windowSize.width - theme.sidebarWidth == 520)
        #expect(theme.pageHorizontalInset == 12)
        #expect(theme.pageHorizontalInset + theme.cardPadding.leading == 28)
        #expect(theme.rowHeight + 1 == 37)
        #expect(theme.cardGap == 8)
        #expect(QuotaProductRow.statusWidth(theme) == 96)
        #expect(QuotaProductRow.nameInset(theme) == 36)
        #expect(QuotaProductRow.rowHeight(theme) == 37)
        #expect(QuotaProductRow.expansionLeading(theme) == QuotaProductRow.nameInset(theme))
    }

    @Test
    func digitsBecomeNumberRunsAndVersionsStayWhole() {
        func runs(_ string: String) -> [String] {
            SettingsNumberText.runs(string).map { $0.isNumber ? "[\($0.text)]" : $0.text }
        }
        #expect(runs("正常 · 26 分钟前") == ["正常 · ", "[26]", " 分钟前"])
        #expect(runs("版本 0.8.1 (47)") == ["版本 ", "[0.8.1 (47)]"])
        #expect(runs("版本 0.8.1 (47) · 外测") == ["版本 ", "[0.8.1 (47)]", " · 外测"])
        #expect(runs("4 / 8 已开启 · 拖动排序") == ["[4]", " / ", "[8]", " 已开启 · 拖动排序"])
        #expect(runs("© 2026 VibeCafé · MIT 许可证") == ["© ", "[2026]", " VibeCafé · MIT 许可证"])
        #expect(runs("同步中…") == ["同步中…"])
        #expect(runs("") == [])
    }

    // MARK: - Menu placement

    private let window = CGSize(width: 700, height: 460)

    @Test
    func menuHangsUnderItsButtonRightAligned() {
        let anchor = CGRect(x: 500, y: 200, width: 150, height: 24)
        let size = SettingsMenuPlacement.size(rows: 3)
        #expect(size == CGSize(width: 172, height: 90))
        let origin = SettingsMenuPlacement.origin(anchor: anchor, menuSize: size, container: window)
        #expect(origin == CGPoint(x: 650 - 172, y: 228))
    }

    @Test
    func menuFlipsAboveWhenTheWindowIsTooShort() {
        let anchor = CGRect(x: 500, y: 400, width: 150, height: 24)
        let size = SettingsMenuPlacement.size(rows: 3)
        let origin = SettingsMenuPlacement.origin(anchor: anchor, menuSize: size, container: window)
        #expect(origin.y == 306, "got \(origin)")
    }

    @Test
    func menuStaysInsideTheWindow() {
        let size = SettingsMenuPlacement.size(rows: 3)
        let nearLeft = SettingsMenuPlacement.origin(
            anchor: CGRect(x: 10, y: 100, width: 60, height: 24), menuSize: size, container: window
        )
        #expect(nearLeft.x == 8)
        // No room above either: stays below rather than leaving the top edge.
        let tiny = CGSize(width: 700, height: 120)
        let cramped = SettingsMenuPlacement.origin(
            anchor: CGRect(x: 500, y: 40, width: 150, height: 24), menuSize: size, container: tiny
        )
        #expect(cramped.y == 68)
    }

    // MARK: - Style switch keeps the window's state

    /// Switching the style only changes the theme the window reads: the
    /// per-window model (drafts, re-link) and navigation are the same objects
    /// with the same contents afterwards.
    @Test @MainActor
    func switchingStyleKeepsDraftsAndNavigation() async throws {
        let suite = "SettingsThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // An external-test build in its own preferences domain: the choice is
        // offered and starts on modern.
        let appState = AppState(
            loadConfig: { nil },
            quotaDefaults: defaults,
            quotaProductDiscoverer: { [] },
            interfaceStyle: InterfaceStylePreference(domain: suite, rollout: .externalTest),
            deviceLinkService: .awaitingApproval
        )
        let model = SettingsModel(appState: appState)
        defer { model.relink.cancel() }
        let navigation = SettingsNavigation(defaults: defaults)
        navigation.page = .directories
        navigation.expandedProviders = [.zCode]
        model.codexExtraHome = "~/work/codex"
        model.zCodeAPIKeyDraft = "draft-key"
        model.relink.start()
        for _ in 0..<200 where model.relinkUserCode == nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(appState.interfaceStyle.canSelect)
        #expect(SettingsTheme.of(appState.interfaceStyle.current).isModern)
        appState.interfaceStyle.select(.classic)
        #expect(!SettingsTheme.of(appState.interfaceStyle.current).isModern)

        #expect(navigation.page == .directories)
        #expect(navigation.expandedProviders == [.zCode])
        #expect(model.codexExtraHome == "~/work/codex")
        #expect(model.zCodeAPIKeyDraft == "draft-key")
        #expect(model.isRelinking)
        #expect(model.relinkUserCode == "WDJB-MJHT")
    }
}

private extension DeviceLinkService {
    /// Hands out a code, then waits for an approval that never comes. No
    /// server, browser or real wait is involved.
    static let awaitingApproval = DeviceLinkService(
        requestCode: { _, _, _ in
            DeviceCodeResponse(deviceCode: "fixture", userCode: "WDJB-MJHT", verificationUri: "",
                               verificationUriComplete: "", expiresIn: 900, interval: 5)
        },
        poll: { _, _ in DevicePollResponse(apiKey: nil, apiUrl: nil, error: "authorization_pending") },
        sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
        now: { Date() },
        openURL: { _ in },
        hostname: { nil }
    )
}
