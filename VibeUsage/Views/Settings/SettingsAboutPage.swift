import SwiftUI

/// 关于: version and update check, the redacted diagnostic summary, and (test
/// builds only) the diagnostic log export.
struct SettingsAboutPage: View {
    @Environment(SettingsModel.self) private var model
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel

    var body: some View {
        SettingsPageScroll {
            SettingsPageHeader(title: SettingsPage.about.title)
            SettingsCard {
                SettingsRow {
                    SettingsRowLabel(title: "版本")
                    Spacer(minLength: 8)
                    Text(SettingsVersion.full)
                        .font(SettingsTheme.mono)
                        .foregroundStyle(SettingsTheme.text)
                    Button("检查更新") { updaterViewModel.checkForUpdates() }
                        .buttonStyle(.settings)
                        .disabled(!updaterViewModel.canCheckForUpdates)
                }
                SettingsSeparator()
                SettingsRow {
                    SettingsRowLabel(title: "VibeCafé")
                    Spacer(minLength: 8)
                    SettingsLinkButton(title: "vibecafe.ai", url: SettingsLinks.vibeCafe)
                }
                SettingsSeparator()
                SettingsRow {
                    SettingsRowLabel(title: "GitHub")
                    Spacer(minLength: 8)
                    SettingsLinkButton(title: "vibe-usage", url: SettingsLinks.cliRepository)
                    SettingsLinkButton(title: "vibe-usage-app", url: SettingsLinks.appRepository)
                }
                SettingsSeparator()
                diagnosticSummaryRow
                #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
                SettingsSeparator()
                SettingsRow(tall: model.diagnosticExportMessage != nil) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text("导出诊断日志")
                                .font(SettingsTheme.label)
                                .foregroundStyle(SettingsTheme.text)
                            SettingsTestBuildTag()
                        }
                        if let message = model.diagnosticExportMessage {
                            Text(message)
                                .font(SettingsTheme.caption)
                                .foregroundStyle(SettingsTheme.secondaryText)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("导出…") { model.exportDiagnosticLog() }
                        .buttonStyle(.settings)
                }
                #endif
            }
        }
    }

    /// The button copies a whitelisted summary (no raw output, paths, keys or
    /// account names); what was copied stays readable underneath.
    @ViewBuilder
    private var diagnosticSummaryRow: some View {
        SettingsRow(tall: true) {
            SettingsRowLabel(title: "复制诊断信息", caption: "已脱敏，可以直接贴到群里")
            Spacer(minLength: 8)
            Button {
                Task { await model.copyDiagnosticSummary() }
            } label: {
                if model.isGeneratingDiagnostics {
                    HStack(spacing: 5) {
                        SettingsSpinner()
                        Text("复制")
                    }
                } else if model.copiedDiagnosticSummary != nil {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(SettingsTheme.green)
                        Text("已复制")
                    }
                } else {
                    SettingsIconLabel(title: "复制", systemImage: "square.on.square")
                }
            }
            .buttonStyle(.settings)
            .disabled(model.isGeneratingDiagnostics)
        }
        if let summary = model.copiedDiagnosticSummary {
            ScrollView {
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SettingsTheme.secondaryText)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            }
            .frame(maxHeight: 150)
            .background(SettingsTheme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(SettingsTheme.line, lineWidth: 1)
            )
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
        }
    }
}

/// Where the 关于 page's links go (maintainer 2026-11-20): the VibeCafé site
/// and the two public repositories, the CLI and this app.
enum SettingsLinks {
    static let vibeCafe = URL(string: "https://vibecafe.ai")!
    static let cliRepository = URL(string: "https://github.com/vibe-cafe/vibe-usage")!
    static let appRepository = URL(string: "https://github.com/vibe-cafe/vibe-usage-app")!
}

/// A settings button that opens a web page in the default browser, marked
/// with the same ↗ arrow as the panel's 「详情」「排行榜」 links.
struct SettingsLinkButton: View {
    let title: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .medium))
            }
        }
        .buttonStyle(.settings)
        .help(url.absoluteString)
        .accessibilityHint("在浏览器中打开")
    }
}
