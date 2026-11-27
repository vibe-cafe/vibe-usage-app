import SwiftUI

/// The Settings window: a sidebar of five pages, the chosen page on the
/// right. 700 × 460 and dark only (finalized design, 2026-11-20). Each page
/// scrolls on its own when it is taller than the window; the sidebar never
/// moves. One set of pages in two looks (`SettingsTheme`), following the
/// interface style: classic (168 pt sidebar, the 2026-11-20 design) or modern
/// (180 pt sidebar and a 520 pt page column, the width of the panel).
///
/// Every control the former single-page form had is still here — see
/// `AGENTS.md` → Settings Window for the page each one moved to.
struct SettingsView: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        SettingsWindowContent()
            .onAppear { model.load() }
    }
}

/// The window's content without the on-appear load (which reads the shared
/// config and asks the CLI), so off-screen renders can draw it from fixtures.
///
/// It picks the theme from the current interface style. Switching the style
/// only changes the environment value: the window, `SettingsModel` (drafts,
/// re-link, save results) and `SettingsNavigation` stay as they are.
struct SettingsWindowContent: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsNavigation.self) private var navigation
    @State private var menu: SettingsMenuState

    init(menu: SettingsMenuState = SettingsMenuState()) {
        _menu = State(initialValue: menu)
    }

    var body: some View {
        let theme = SettingsTheme.of(appState.interfaceStyle.current)
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: theme.sidebarWidth - 1)
            theme.line
                .frame(width: 1)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { Rectangle().fill(theme.background) }
        }
        // The window owns the size (700 wide, at least 460 tall); a SwiftUI
        // minimum here would be applied below the title bar and add its height.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(theme.background) }
        .overlay { SettingsMenuOverlay() }
        .coordinateSpace(.named(SettingsMenuState.space))
        // The sidebar and the page run under the transparent title bar.
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .environment(\.settingsTheme, theme)
        .environment(menu)
        .tint(theme.tint)
        .onChange(of: theme.style) { _, _ in menu.close() }
        .onChange(of: navigation.page) { _, _ in menu.close() }
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.page {
        case .general: SettingsGeneralPage()
        case .quotas: SettingsQuotaPage()
        case .sync: SettingsSyncPage()
        case .directories: SettingsDirectoriesPage()
        case .about: SettingsAboutPage()
        }
    }
}

/// The scrolling column every page sits in. Classic: 20 pt from the top,
/// 22 pt from the sides, 22 pt of air after the last card (a page may ask
/// for less). Modern: cards 12 pt from the sides (text at 28, the panel's
/// line), 14 pt after the last card.
struct SettingsPageScroll<Content: View>: View {
    var bottomInset: CGFloat?
    @ViewBuilder var content: Content
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.top, theme.pageTopInset)
            .padding(.horizontal, theme.pageHorizontalInset)
            .padding(.bottom, theme.isModern ? theme.pageBottomInset : (bottomInset ?? theme.pageBottomInset))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsNavigation.self) private var navigation
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.isModern ? 2 : 1) {
            ForEach(SettingsPage.allCases) { page in
                item(page)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.top, 52)
        .padding(.horizontal, theme.isModern ? 12 : 10)
        .padding(.bottom, theme.isModern ? 14 : 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { Rectangle().fill(theme.sidebarBackground) }
    }

    private func item(_ page: SettingsPage) -> some View {
        let isSelected = navigation.page == page
        let shape = RoundedRectangle(cornerRadius: theme.isModern ? 6 : 7, style: .continuous)
        return Button {
            navigation.page = page
        } label: {
            HStack(spacing: theme.isModern ? 8 : 9) {
                Image(systemName: page.systemImage)
                    .font(.system(size: theme.isModern ? 12 : 13, weight: .regular))
                    .frame(width: theme.isModern ? 14 : 16, height: theme.isModern ? 14 : 16)
                Text(page.title)
                    .font(theme.isModern ? SettingsFont.text(13, isSelected ? .semibold : .medium) : theme.label)
                Spacer(minLength: 4)
                trailing(page)
            }
            // Modern: the unselected pages step back, like the panel's
            // secondary text.
            .foregroundStyle(theme.isModern && !isSelected ? theme.secondaryText : theme.text)
            .padding(.horizontal, theme.isModern ? 8 : 9)
            .frame(height: theme.isModern ? 28 : 30)
            .background(isSelected ? theme.selection : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The sidebar carries one mark only: a red dot on 数据同步 after a failed
    /// sync, visible from every page (maintainer 2026-11-20, 「按这三点改」:
    /// no count, no green dot, no 「高级」 chip in the sidebar).
    @ViewBuilder
    private func trailing(_ page: SettingsPage) -> some View {
        if page == .sync,
           let dot = SettingsSyncSummary.sidebarDot(status: appState.syncStatus, isConfigured: appState.isConfigured) {
            SettingsStatusDot(kind: dot)
                .padding(.trailing, theme.isModern ? 2 : 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            // The row is about 131 pt wide. The version always shows in full
            // (an 8 pt gap and a fixed-width name cut 「0.7.10」 to 「0.7.…」);
            // when the row is too narrow the gap shrinks to 4 pt and then the
            // name is shortened instead (the external-test 「Vibe Usage Test」).
            // 关于 shows both in full.
            Text(AppConfig.displayName)
                .font(theme.caption)
                .lineLimit(1)
                .padding(.leading, theme.isModern ? 7 : 8)
            Spacer(minLength: 4)
            Text(SettingsVersion.short)
                .font(theme.isModern ? SettingsFont.number(11) : .system(size: 11, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 8)
    }
}

/// Version strings from the bundle (falls back to `AppConfig` when run
/// outside a bundle).
enum SettingsVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppConfig.version
    }

    /// 「0.7.6 (42)」, plus 「· 外测」 for external-test builds.
    static var full: String {
        var text = short
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            text += " (\(build))"
        }
        if AppConfig.isExternalTest { text += " · 外测" }
        return text
    }
}
