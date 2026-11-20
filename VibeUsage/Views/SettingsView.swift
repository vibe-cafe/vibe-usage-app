import SwiftUI

/// The Settings window: a 168 pt sidebar of five pages, the chosen page on the
/// right. 700 × 460 and dark only (finalized design, 2026-11-20). Each page
/// scrolls on its own when it is taller than the window; the sidebar never
/// moves.
///
/// Every control the former single-page form had is still here — see
/// `AGENTS.md` → Settings Window for the page each one moved to.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsNavigation.self) private var navigation
    @Environment(SettingsModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: SettingsTheme.sidebarWidth - 1)
            SettingsTheme.line
                .frame(width: 1)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { Rectangle().fill(SettingsTheme.content) }
        }
        // The window owns the size (700 wide, at least 460 tall); a SwiftUI
        // minimum here would be applied below the title bar and add its height.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(SettingsTheme.content) }
        // The sidebar and the page run under the transparent title bar.
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .tint(SettingsTheme.green)
        .onAppear { model.load() }
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

/// The scrolling column every page sits in: 20 pt from the top, 22 pt from
/// the sides, 22 pt of air after the last card.
struct SettingsPageScroll<Content: View>: View {
    var bottomInset: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.top, SettingsTheme.contentTopInset)
            .padding(.horizontal, SettingsTheme.contentHorizontalInset)
            .padding(.bottom, bottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsNavigation.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsPage.allCases) { page in
                item(page)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.top, 52)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { Rectangle().fill(SettingsTheme.sidebar) }
    }

    private func item(_ page: SettingsPage) -> some View {
        let isSelected = navigation.page == page
        return Button {
            navigation.page = page
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 16, height: 16)
                Text(page.title)
                    .font(SettingsTheme.label)
                Spacer(minLength: 4)
                trailing(page)
            }
            .foregroundStyle(SettingsTheme.text)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                isSelected ? SettingsTheme.selection : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The sidebar carries one mark only: a red dot on 数据同步 after a failed
    /// sync, visible from every page (maintainer 2026-11-20, 「按这三点改」:
    /// no count, no green dot, no 「高级」 chip in the sidebar).
    @ViewBuilder
    private func trailing(_ page: SettingsPage) -> some View {
        if page == .sync, let dot = SettingsSyncSummary.sidebarDot(status: appState.syncStatus) {
            SettingsStatusDot(kind: dot)
                .padding(.trailing, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text(AppConfig.displayName)
                .font(SettingsTheme.caption)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 8)
            Spacer(minLength: 8)
            Text(SettingsVersion.short)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(SettingsTheme.secondaryText)
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
