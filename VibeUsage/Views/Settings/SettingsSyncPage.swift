import SwiftUI

/// 数据同步: the account key and re-linking, sync health with the last ten
/// runs, and the reset.
struct SettingsSyncPage: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsModel.self) private var model
    @State private var showingResetConfirmation = false

    var body: some View {
        SettingsPageScroll {
            SettingsPageHeader(title: SettingsPage.sync.title)
            SettingsCard {
                keyRow
                if model.isRelinking, let code = model.relinkUserCode {
                    codeBox(code)
                        .padding(.leading, 14)
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                }
                SettingsSeparator()
                syncRow
                SettingsSeparator()
                SettingsRow(tall: true) {
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
        SettingsRow(tall: model.relinkError != nil) {
            SettingsRowLabel(title: "API Key", caption: model.relinkError, captionColor: SettingsTheme.red)
            Spacer(minLength: 8)
            if model.hasAPIKey {
                Text(model.apiKeyDisplay)
                    .font(SettingsTheme.mono)
                    .foregroundStyle(SettingsTheme.text)
                    .lineLimit(1)
            } else {
                Text("未配置")
                    .font(SettingsTheme.body)
                    .foregroundStyle(SettingsTheme.secondaryText)
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
    private func codeBox(_ code: String) -> some View {
        HStack(spacing: 10) {
            Text("验证码")
                .font(SettingsTheme.body)
                .foregroundStyle(SettingsTheme.secondaryText)
            Text(code)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(SettingsTheme.text)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            SettingsSpinner()
            Text("等浏览器里确认…")
                .font(SettingsTheme.body)
                .foregroundStyle(SettingsTheme.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(SettingsTheme.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SettingsTheme.line, lineWidth: 1)
        )
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
                Text(line.text)
                    .font(SettingsTheme.body)
                    .foregroundStyle(
                        line.kind == .error ? SettingsTheme.red
                            : (appState.isConfigured ? SettingsTheme.text : SettingsTheme.tertiaryText)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(line.text)
            }
        }
    }
}

/// The last ten syncs as thin bars, oldest first: green for a success, red
/// for a failure; the newest bar is full strength. Read from the app's local
/// sync history (`SyncHistoryStore`), nothing new is recorded for it.
struct SyncBars: View {
    let bars: [Bool]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, success in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(success ? SettingsTheme.green : SettingsTheme.red)
                    .opacity(index == bars.count - 1 ? 1 : (success ? 0.6 : 0.95))
                    .frame(width: 3, height: 11)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("最近 \(bars.count) 次同步，失败 \(bars.filter { !$0 }.count) 次")
    }
}
