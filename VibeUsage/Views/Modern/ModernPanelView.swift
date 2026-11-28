import SwiftUI

/// The height of the new panel. The header (title row plus the 概览 row) and
/// the footer always show; the cards between them take their natural height
/// and scroll once the panel would be taller than the screen allows.
enum ModernPanelHeight {
    /// Height of the scrolling middle.
    static func middle(content: CGFloat, chrome: CGFloat, maxHeight: CGFloat) -> CGFloat {
        max(0, min(content, maxHeight - chrome))
    }

    /// Height the whole panel asks for.
    static func panel(content: CGFloat, chrome: CGFloat, maxHeight: CGFloat) -> CGFloat {
        chrome + middle(content: content, chrome: chrome, maxHeight: maxHeight)
    }
}

/// Shared by `MenuBarController` and the panel: how tall the panel may be on
/// the screen it opens on. The controller updates it on every open.
@Observable
@MainActor
final class ModernPanelLayout {
    var maxHeight: CGFloat = .infinity
}

/// Root of the menu-bar panel: the classic dashboard or the new panel,
/// following `interfaceStyle` live, so switching the style swaps the panel
/// without a restart.
struct PanelRootView: View {
    @Environment(AppState.self) private var appState
    let layout: ModernPanelLayout
    /// The new panel's preferred height; the classic panel is fixed-size.
    var onModernHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        switch appState.interfaceStyle.current {
        case .classic:
            PopoverView()
        case .modern:
            ModernPanelView(maxHeight: layout.maxHeight, onPreferredHeightChange: onModernHeightChange)
                .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                    .receive(on: DispatchQueue.main)) { _ in
                    appState.calendarDayDidChange()
                }
        }
    }
}

/// The new panel (design 131, 136): header, 概览 row, 订阅配额 and 近期消耗
/// cards, footer. 订阅配额 is `ModernQuotaCardBody` (131–133). Without a
/// linked account 近期消耗 holds the sign-in (136j–136l); with one, the
/// figures, the curve and the filter menu (134). 展开详情 adds the four
/// details cards (135).
struct ModernPanelView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    var maxHeight: CGFloat = .infinity
    var onPreferredHeightChange: (CGFloat) -> Void = { _ in }

    @State private var headerHeight: CGFloat?
    @State private var footerHeight: CGFloat?
    @State private var contentHeight: CGFloat?
    /// Prototype (#113): the switch-back banner after the classic banner's
    /// 「切换新版」; a renderer turns it on, × or the path ends it.
    @Environment(\.modernSwitchBackNotice) private var showsSwitchBackNotice
    @State private var switchBackNoticeDismissed = false

    private var enabled: [ProviderRateLimit.Provider] { appState.quotaCardProviders }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ModernHeaderBar(hasUpdate: updaterViewModel.availableUpdate != nil) {
                    updaterViewModel.checkForUpdates()
                } openSettings: {
                    SettingsWindowController.shared.show(appState: appState, updaterViewModel: updaterViewModel)
                }
                if enabled.count > 1 {
                    ModernSubscriptionRow {
                        SettingsWindowController.shared.show(
                            appState: appState, updaterViewModel: updaterViewModel,
                            destination: .quotas(focus: nil)
                        )
                    }
                } else {
                    // One subscription opens straight on it and none has
                    // nothing to choose: no 概览 row (132f, 132g).
                    Color.clear.frame(height: 4)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            ScrollView(.vertical) {
                cards
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // A scroller would take width from the 520 pt stack (with the
            // system's 「始终显示滚动条」 it does) and shift the cards left;
            // the cards stay put whether or not the middle scrolls.
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: middleHeight)

            ModernFooterBar()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .coordinateSpace(.named(UsageFilterMenuState.space))
        // 近期消耗's filter menu, drawn over the whole panel.
        .overlay { UsageFilterMenuOverlay() }
        .environment(appState.modernPanel.filterMenu)
        .frame(width: ModernTheme.panelWidth)
        // The window, sized by `MenuBarController` from `preferredHeight`,
        // decides the height; the content stays pinned to the top and never
        // imposes a minimum the window would have to satisfy.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        // Above every card and the scroller, so a row's tooltip is never cut
        // off by the card or the scrolling middle.
        .overlayPreferenceValue(ModernQuotaTooltipKey.self) { ModernQuotaTooltipOverlay(value: $0) }
        .background(ModernTheme.panel)
        .environment(\.colorScheme, .dark)
        .onChange(of: preferredHeight, initial: true) { _, height in
            if let height { onPreferredHeightChange(height) }
        }
    }

    private var chromeHeight: CGFloat { (headerHeight ?? 0) + (footerHeight ?? 0) }

    private var middleHeight: CGFloat {
        ModernPanelHeight.middle(content: contentHeight ?? 0, chrome: chromeHeight, maxHeight: maxHeight)
    }

    /// Nil until every part has been measured once.
    private var preferredHeight: CGFloat? {
        guard headerHeight != nil, footerHeight != nil, let contentHeight else { return nil }
        return ModernPanelHeight.panel(content: contentHeight, chrome: chromeHeight, maxHeight: maxHeight).rounded(.up)
    }

    private var cards: some View {
        VStack(spacing: ModernTheme.cardSpacing) {
            // Prototype (#113): first in the scrolling middle, under the 概览
            // row (or the header with one subscription). It counts in the
            // content height, so the panel grows by it and shrinks back on ×.
            if showsSwitchBackNotice && !switchBackNoticeDismissed {
                ModernSwitchBackBanner {
                    switchBackNoticeDismissed = true
                    SettingsWindowController.shared.show(
                        appState: appState, updaterViewModel: updaterViewModel, destination: .general
                    )
                } dismiss: {
                    switchBackNoticeDismissed = true
                }
            }

            ModernCard(title: "订阅配额") {
                if let scope = appState.modernPanel.quotaRefreshScope(enabled: enabled) {
                    ModernRefreshQuotasButton(scope: scope)
                }
            } content: {
                ModernQuotaCardBody()
            }

            ModernCard(title: "近期消耗") {
                if appState.isConfigured { RecentUsageControls() }
            } content: {
                if appState.isConfigured {
                    ModernRecentUsageBody()
                } else {
                    // Not linked: the same card walks through the sign-in.
                    ModernSignInBody()
                }
            }

            if appState.isConfigured && appState.modernPanel.detailsExpanded {
                ModernDetailsSection()
            }
        }
        .padding(.horizontal, ModernTheme.cardInset)
        .frame(width: ModernTheme.panelWidth)
    }
}

/// A card: the title row (13 pt, secondary) with an optional control at its
/// right edge, then the body 8 pt below.
struct ModernCard<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(ModernTheme.text(13, .semibold))
                    .foregroundStyle(ModernTheme.secondaryText)
                Spacer(minLength: 0)
                accessory
            }
            .frame(height: 20)
            content
        }
        .padding(ModernTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernCardBackground())
    }
}

/// 「刷新额度」 (132s–132u): quotas only — 概览 reads every enabled
/// subscription, a subscription's detail reads that one. It spins, and does
/// not take clicks, while a read in its scope is in flight, including the
/// reads an open starts on their own.
struct ModernRefreshQuotasButton: View {
    @Environment(AppState.self) private var appState
    let scope: QuotaRefreshScope

    var body: some View {
        let isRefreshing = appState.isRefreshingQuotas(scope)
        Button {
            Task { await appState.refreshQuotas(scope) }
        } label: {
            Group {
                if isRefreshing {
                    ModernSpinner(size: 13)
                } else {
                    Image(systemName: "arrow.2.circlepath")
                        .font(.system(size: 10.5, weight: .medium))
                }
            }
            .frame(width: 14, height: 14)
            .modernHitArea()
        }
        .buttonStyle(ModernIconButtonStyle(color: ModernTheme.secondaryText))
        .disabled(isRefreshing)
        .help("刷新额度")
        .accessibilityLabel("刷新额度")
    }
}
