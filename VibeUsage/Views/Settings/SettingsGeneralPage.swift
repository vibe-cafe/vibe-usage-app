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

/// A slice of the top of a screen: the menu bar at its real height with our
/// status item and the clock on the right, the desktop below it — the way
/// System Settings previews Appearance above its controls. The status item is
/// the real one (`MenuBarLabel` fed by `MenuBarLabel.lines(for:)`): only the
/// icon until there is usage, then cost and / or Token, stacked in two lines
/// when both switches are on. Nothing from other apps is drawn.
struct MenuBarPreview: View {
    @Environment(AppState.self) private var appState

    /// The menu bar's height on this Mac: 24 pt, taller beside a notch. Read
    /// from the main screen (frame minus visible frame); an auto-hidden menu
    /// bar reports 0, so 24 is the floor.
    private static var barHeight: CGFloat {
        guard let screen = NSScreen.main else { return 24 }
        return max(24, screen.frame.maxY - screen.visibleFrame.maxY)
    }
    private static let desktopHeight: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                MenuBarLabel(icon: MenuBarLabel.statusIcon, lines: MenuBarLabel.lines(for: appState))
                Image(systemName: "switch.2")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityHidden(true)
                MenuBarClock()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: Self.barHeight)
            .background { Rectangle().fill(Color.black.opacity(0.34)) }
            .overlay(alignment: .bottom) { Color.white.opacity(0.06).frame(height: 1) }
            Color.clear.frame(height: Self.desktopHeight)
        }
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(
                colors: [Color(settingsHex: 0x3A3A3A), Color(settingsHex: 0x2B2B2B)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(SettingsTheme.line, lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("菜单栏预览")
        .accessibilityValue(MenuBarLabel.lines(for: appState).joined(separator: "，"))
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
