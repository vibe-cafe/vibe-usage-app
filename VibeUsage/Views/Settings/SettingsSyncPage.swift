import SwiftUI

/// 数据同步: the account key and re-linking, sync health with the last ten
/// runs, and the reset.
struct SettingsSyncPage: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsModel.self) private var model
    @Environment(\.settingsTheme) private var theme
    @State private var showingResetConfirmation = false

    var body: some View {
        SettingsPageScroll {
            SettingsPageHeader(title: SettingsPage.sync.title)
            SettingsCard {
                keyRow
                if model.isRelinking, let code = model.relinkUserCode {
                    codeBox(code)
                        .padding(.leading, theme.isModern ? 0 : 14)
                        .padding(.trailing, theme.isModern ? 0 : 12)
                        .padding(.bottom, theme.isModern ? 10 : 12)
                }
                SettingsSeparator()
                syncRow
                SettingsSeparator()
                SettingsRow(tall: !theme.isModern) {
                    SettingsRowLabel(title: "重置配置")
                    Spacer(minLength: 8)
                    Button("重置…") { showingResetConfirmation = true }
                        .buttonStyle(.settingsDanger)
                }
            }
        }
        .alert("确定要重置配置吗？", isPresented: $showingResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) { model.resetConfig() }
        } message: {
            Text("这将清除 API Key 并停止自动同步。")
        }
    }

    // MARK: - API Key

    private var keyRow: some View {
        SettingsRow(tall: model.relinkError != nil, spacing: theme.isModern ? 12 : 10) {
            SettingsRowLabel(title: "API Key", caption: model.relinkError, captionColor: theme.red)
            Spacer(minLength: 8)
            if model.hasAPIKey {
                Text(model.apiKeyDisplay)
                    .font(theme.mono)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
            } else {
                Text("未配置")
                    .font(theme.body)
                    .foregroundStyle(theme.secondaryText)
            }
            if model.isRelinking {
                Button("取消") { model.cancelRelink() }
                    .buttonStyle(.settings)
            } else if model.hasAPIKey {
                Button("重新链接") { model.startRelink() }
                    .buttonStyle(.settings)
            } else {
                Button("链接") { model.startRelink() }
                    .buttonStyle(.settingsPrimary)
            }
        }
    }

    /// The device-flow code to compare with the browser, while it waits.
    /// Classic: in an inset box. Modern: the row's second line, no box.
    private func codeBox(_ code: String) -> some View {
        HStack(spacing: 10) {
            Text("验证码")
                .font(theme.status)
                .foregroundStyle(theme.secondaryText)
            Text(code)
                .font(theme.isModern
                    ? SettingsFont.number(15, .medium)
                    : .system(size: 15, weight: .semibold, design: .monospaced))
                .tracking(theme.isModern ? 0.9 : 1.2)
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            SettingsSpinner()
            Text("等浏览器里确认…")
                .font(theme.status)
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, theme.isModern ? 0 : 12)
        .frame(height: theme.isModern ? 20 : 40)
        .background {
            if !theme.isModern {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.inset)
            }
        }
        .overlay {
            if !theme.isModern {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line, lineWidth: 1)
            }
        }
    }

    // MARK: - Sync

    private var syncRow: some View {
        let line = SettingsSyncSummary.line(
            status: appState.syncStatus,
            isConfigured: appState.isConfigured,
            lastSync: appState.lastSyncTime
        )
        let bars = appState.isConfigured ? SettingsSyncSummary.bars(from: appState.syncHistory.records()) : []
        return SettingsRow {
            SettingsRowLabel(title: "同步")
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                if !bars.isEmpty {
                    SyncBars(bars: bars)
                        .padding(.trailing, 4)
                        .help("最近 \(bars.count) 次同步")
                }
                if line.isSpinning { SettingsSpinner() }
                if let kind = line.kind { SettingsStatusDot(kind: kind) }
                SettingsNumberText.text(
                    line.text,
                    font: theme.isModern && appState.isConfigured ? theme.status : theme.body,
                    numberFont: theme.numberFont?(.regular)
                )
                    .foregroundStyle(lineColor(line))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(line.text)
            }
        }
    }
}

extension SettingsSyncPage {
    /// Classic: the line in the text color, grey while unlinked. Modern: the
    /// panel's secondary text (state words are quiet), grey 「—」 while
    /// unlinked. An error is red in both.
    fileprivate func lineColor(_ line: SettingsSyncSummary.Line) -> Color {
        if line.kind == .error { return theme.red }
        if !appState.isConfigured { return theme.tertiaryText }
        return theme.isModern ? theme.secondaryText : theme.text
    }
}

/// The last ten syncs as thin bars, oldest first: a success (classic green,
/// modern the panel's warm white), a failure red; the newest bar is full
/// strength. Read from the app's local sync history (`SyncHistoryStore`),
/// nothing new is recorded for it.
struct SyncBars: View {
    let bars: [Bool]
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, success in
                let newest = index == bars.count - 1
                RoundedRectangle(cornerRadius: theme.isModern ? 1 : 1.5, style: .continuous)
                    .fill(success ? successColor : theme.red)
                    .opacity(opacity(success: success, newest: newest))
                    .frame(width: 3, height: 11)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("最近 \(bars.count) 次同步，失败 \(bars.filter { !$0 }.count) 次")
    }

    /// Modern: the panel's ring color, `rgb(237,233,225)`.
    private var successColor: Color {
        theme.isModern ? Color(.sRGB, red: 237 / 255, green: 233 / 255, blue: 225 / 255) : theme.ok
    }

    private func opacity(success: Bool, newest: Bool) -> Double {
        if theme.isModern { return success ? (newest ? 0.9 : 0.42) : 1 }
        return newest ? 1 : (success ? 0.6 : 0.95)
    }
}
