import SwiftUI

/// 通用: what the app shows in the menu bar, and how it starts.
struct SettingsGeneralPage: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsModel.self) private var model

    var body: some View {
        SettingsPageScroll {
            SettingsPageHeader(title: SettingsPage.general.title)
            SettingsCard {
                SettingsRow {
                    SettingsRowLabel(title: "菜单栏显示费用")
                    Spacer(minLength: 8)
                    MenuBarPreview()
                        .padding(.trailing, 6)
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
                SettingsSeparator()
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
        }
    }
}

/// The status item, drawn by the status item's own view (`MenuBarLabel`)
/// with the same rule for what it shows: only the icon until there is usage,
/// then cost and / or Token — stacked in two lines when both switches are on.
/// It sits on a dark strip the height of the menu bar.
struct MenuBarPreview: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        MenuBarLabel(icon: MenuBarLabel.statusIcon, lines: MenuBarLabel.lines(for: appState))
            .padding(.horizontal, 5)
            .frame(height: 24)
            .background(SettingsTheme.menuBarFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .top) {
                Color.white.opacity(0.12)
                    .frame(height: 0.5)
                    .padding(.horizontal, 6)
            }
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("菜单栏预览")
    }
}
