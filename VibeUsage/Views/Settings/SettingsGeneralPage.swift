import SwiftUI

/// 通用: what the app shows in the menu bar, and how it starts.
struct SettingsGeneralPage: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsModel.self) private var model

    var body: some View {
        SettingsPageScroll {
            SettingsPageHeader(title: SettingsPage.general.title)
            MenuBarPreview()
            SettingsCard {
                SettingsRow {
                    SettingsRowLabel(title: "菜单栏显示费用")
                    Spacer(minLength: 8)
                    Toggle("菜单栏显示费用", isOn: Binding(
                        get: { appState.showCostInMenuBar },
                        set: { appState.showCostInMenuBar = $0 }
                    ))
                    .toggleStyle(.settingsSwitch)
                }
                SettingsSeparator()
                SettingsRow {
                    SettingsRowLabel(title: "菜单栏显示 Token")
                    Spacer(minLength: 8)
                    Toggle("菜单栏显示 Token", isOn: Binding(
                        get: { appState.showTokensInMenuBar },
                        set: { appState.showTokensInMenuBar = $0 }
                    ))
                    .toggleStyle(.settingsSwitch)
                }
            }
            .padding(.top, 16)
            SettingsCard {
                SettingsRow {
                    SettingsRowLabel(title: "开机自启动")
                    Spacer(minLength: 8)
                    Toggle("开机自启动", isOn: Binding(
                        get: { model.autoStartEnabled },
                        set: { model.setAutoStart($0) }
                    ))
                    .toggleStyle(.settingsSwitch)
                }
                SettingsSeparator()
                SettingsRow(tall: true) {
                    SettingsRowLabel(title: "在 Dock 中显示", caption: "关闭设置窗口后生效")
                    Spacer(minLength: 8)
                    Toggle("在 Dock 中显示", isOn: Binding(
                        get: { appState.showInDock },
                        set: { appState.showInDock = $0 }
                    ))
                    .toggleStyle(.settingsSwitch)
                }
            }
            .padding(.top, 16)
        }
    }
}

/// A slice of the top of a screen: the user's own desktop picture with the
/// menu bar floating on it — transparent since macOS 26 — our status item and
/// the clock on the right, the way System Settings previews Wallpaper and
/// Appearance above their controls. The status item is the real one
/// (`MenuBarLabel` fed by `MenuBarLabel.lines(for:)`): only the icon until
/// there is usage, then cost and / or Token, stacked in two lines when both
/// switches are on. The text turns dark over a bright picture, like the real
/// menu bar. Nothing from other apps is drawn.
///
/// The picture comes from `MenuBarWallpaper` (protected places are never
/// read; anything unreadable falls back to a drawn gradient) and lives only in
/// this view's state: it is read when the preview appears and released when
/// the page changes or the window closes.
struct MenuBarPreview: View {
    @Environment(AppState.self) private var appState
    @Environment(\.displayScale) private var displayScale
    @State private var screen: NSScreen?
    @State private var wallpaper: MenuBarWallpaper.Strip?

    private static let desktopHeight: CGFloat = 48
    private static let width = SettingsTheme.windowSize.width - SettingsTheme.sidebarWidth
        - SettingsTheme.contentHorizontalInset * 2

    /// The menu bar's height on the window's screen: 24 pt, taller beside a
    /// notch (frame minus visible frame; an auto-hidden menu bar reports 0).
    private var barHeight: CGFloat {
        guard let screen = screen ?? NSScreen.main else { return 24 }
        return max(24, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    var body: some View {
        let height = barHeight + Self.desktopHeight
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                MenuBarLabel(icon: MenuBarLabel.statusIcon, lines: MenuBarLabel.lines(for: appState))
                Image(systemName: "switch.2")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityHidden(true)
                MenuBarClock()
            }
            .foregroundStyle(.primary)
            .environment(\.colorScheme, wallpaper?.prefersDarkText == true ? .light : .dark)
            .padding(.horizontal, 12)
            .frame(height: barHeight)
            Color.clear.frame(height: Self.desktopHeight)
        }
        .frame(maxWidth: .infinity)
        .background {
            if let wallpaper {
                Image(decorative: wallpaper.image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                MenuBarWallpaperFallback()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(SettingsTheme.line, lineWidth: 1)
        )
        .background { WindowScreenReader { screen = $0 } }
        .task(id: ScreenKey(screen: screen, height: height, scale: displayScale)) {
            let url = (screen ?? NSScreen.main).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            let pixelWidth = Int(Self.width * displayScale)
            let aspect = Self.width / height
            let fraction = barHeight / height
            wallpaper = await Task.detached(priority: .utility) {
                MenuBarWallpaper.loadStrip(url: url, pixelWidth: pixelWidth, aspect: aspect, menuBarFraction: fraction)
            }.value
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("菜单栏预览")
        .accessibilityValue(MenuBarLabel.lines(for: appState).joined(separator: "，"))
    }

    /// Re-read only when the screen, the preview's height or the scale changes.
    private struct ScreenKey: Equatable {
        let displayID: UInt32?
        let height: CGFloat
        let scale: CGFloat

        init(screen: NSScreen?, height: CGFloat, scale: CGFloat) {
            displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            self.height = height
            self.scale = scale
        }
    }
}

/// The menu-bar clock, in the menu bar's own font, ticking once a minute.
private struct MenuBarClock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.format(context.date))
                .font(Font(NSFont.menuBarFont(ofSize: 0)))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityHidden(true)
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }
}
