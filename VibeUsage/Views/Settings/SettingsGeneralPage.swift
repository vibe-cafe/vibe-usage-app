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
                    MenuBarPreview(
                        cost: appState.showCostInMenuBar ? Formatters.formatCost(appState.menuBarCost) : nil,
                        tokens: appState.showTokensInMenuBar ? Formatters.formatNumber(appState.menuBarTokens) : nil
                    )
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

/// A small dark chip that mirrors the status item: the icon, then the cost
/// and Token figures the two switches turn on, so the effect is visible
/// without looking up at the menu bar.
struct MenuBarPreview: View {
    let cost: String?
    let tokens: String?

    var body: some View {
        HStack(spacing: 6) {
            Self.icon
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: 13, height: 13)
            if let cost { Text(cost) }
            if let tokens { Text(tokens) }
        }
        .font(SettingsTheme.mono)
        .foregroundStyle(SettingsTheme.menuBarText)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(SettingsTheme.menuBarFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .top) {
            Color.white.opacity(0.12)
                .frame(height: 0.5)
                .padding(.horizontal, 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("菜单栏预览")
    }

    private static var icon: Image {
        if let url = Bundle.appResources.url(forResource: "menubar-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return Image(nsImage: image)
        }
        return Image(systemName: "chart.bar.fill")
    }
}
