import SwiftUI

/// 关于, laid out like the About page Hogan liked (CodexBar's, 2026-11-20:
/// 「我觉得这个设计还不错啊」): an identity card (icon, name, version), then
/// 更新, 诊断 and 链接 groups, and the copyright line.
struct SettingsAboutPage: View {
    @Environment(SettingsModel.self) private var model
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        SettingsPageScroll {
            SettingsPageHeader(title: SettingsPage.about.title)
            identityCard

            SettingsSection(title: "更新") {
                SettingsRow {
                    SettingsRowLabel(title: "版本 \(SettingsVersion.full)")
                    Spacer(minLength: 8)
                    Button("检查更新…") { updaterViewModel.checkForUpdates() }
                        .buttonStyle(.settings)
                        .disabled(!updaterViewModel.canCheckForUpdates)
                }
            }

            SettingsSection(title: "诊断") {
                diagnosticSummaryRow
                #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
                SettingsSeparator()
                SettingsRow(tall: model.diagnosticExportMessage != nil) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text("导出诊断日志")
                                .font(theme.label)
                                .foregroundStyle(theme.text)
                            SettingsTestBuildTag()
                        }
                        if let message = model.diagnosticExportMessage {
                            Text(message)
                                .font(theme.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("导出…") { model.exportDiagnosticLog() }
                        .buttonStyle(.settings)
                }
                #endif
            }

            SettingsSection(title: "链接") {
                SettingsLinkRow(title: "vibe-usage", url: SettingsLinks.cliRepository) {
                    GitHubMark().fill(style: FillStyle(eoFill: true))
                }
                SettingsSeparator()
                SettingsLinkRow(title: "vibe-usage-app", url: SettingsLinks.appRepository) {
                    GitHubMark().fill(style: FillStyle(eoFill: true))
                }
                SettingsSeparator()
                SettingsLinkRow(title: "VibeCafé", url: model.appState.usageServer.siteURL) {
                    Image(systemName: "globe")
                        .resizable()
                        .scaledToFit()
                }
            }

            SettingsNumberText("© 2026 VibeCafé · MIT 许可证", font: theme.caption)
                .foregroundStyle(theme.isModern ? theme.secondaryText : theme.tertiaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, theme.isModern ? 14 : 18)
        }
    }

    /// Icon, name and version, centered.
    private var identityCard: some View {
        SettingsCard {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 68, height: 68)
                    .accessibilityHidden(true)
                Text(AppConfig.displayName)
                    .font(theme.pageTitle)
                    .tracking(theme.pageTitleTracking)
                    .foregroundStyle(theme.text)
                    .padding(.top, 8)
                SettingsNumberText("版本 \(SettingsVersion.full)", font: theme.caption)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, theme.isModern ? 2 : 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, theme.isModern ? 12 : 18)
            .padding(.bottom, theme.isModern ? 10 : 18)
        }
    }

    /// The button copies a whitelisted summary (no raw output, paths, keys or
    /// account names); what was copied stays readable underneath.
    @ViewBuilder
    private var diagnosticSummaryRow: some View {
        SettingsRow(tall: !theme.isModern) {
            SettingsRowLabel(title: "复制诊断信息")
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
                        SettingsCheckMark()
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
                    .font(theme.isModern ? SettingsFont.number(11) : .system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(theme.isModern ? 4 : 3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, theme.isModern ? 8 : 9)
            }
            .frame(maxHeight: theme.isModern ? 118 : 150)
            .background(theme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if !theme.isModern {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.line, lineWidth: 1)
                }
            }
            .padding(.leading, theme.isModern ? 0 : 14)
            .padding(.trailing, theme.isModern ? 0 : 12)
            .padding(.bottom, theme.isModern ? 10 : 12)
        }
    }
}

/// Public repositories on the 关于 page. The VibeCafé site follows the configured server.
enum SettingsLinks {
    static let cliRepository = URL(string: "https://github.com/vibe-cafe/vibe-usage")!
    static let appRepository = URL(string: "https://github.com/vibe-cafe/vibe-usage-app")!
}

/// One row of the 链接 card: a monochrome mark, the name, a grey ↗ at the
/// end. The whole row is the link (default browser) and lightens slightly
/// under the pointer; no framed button.
struct SettingsLinkRow<Mark: View>: View {
    let title: String
    let url: URL?
    @ViewBuilder var mark: Mark
    @State private var isHovered = false
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: theme.isModern ? 0 : 10) {
                mark
                    .foregroundStyle(theme.isModern ? theme.ok : theme.text)
                    .frame(width: theme.isModern ? 14 : 15, height: theme.isModern ? 14 : 15)
                    .frame(width: theme.isModern ? 22 : 18, height: 18, alignment: theme.isModern ? .leading : .center)
                    .accessibilityHidden(true)
                Text(title)
                    .font(theme.label)
                    .foregroundStyle(theme.text)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: theme.isModern ? 10 : 11, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)
            }
            .padding(.leading, theme.isModern ? 0 : 14)
            .padding(.trailing, theme.isModern ? 0 : 14)
            .frame(minHeight: theme.rowHeight)
            .background {
                // Classic: the whole row lightens. Modern: a rounded wash
                // reaching 8 pt into the card's padding, like the panel's rows.
                RoundedRectangle(cornerRadius: theme.isModern ? 6 : 0, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? (theme.isModern ? 0.05 : 0.04) : 0))
                    .padding(.horizontal, theme.isModern ? -8 : 0)
            }
            .padding(.top, theme.isModern ? 1 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(url == nil)
        .help(url?.absoluteString ?? "")
        .accessibilityAddTraits(.isLink)
        .accessibilityHint("在浏览器中打开")
    }
}

/// The GitHub mark, Simple Icons `github.svg` (simple-icons 16.38.0,
/// https://github.com/simple-icons/simple-icons, CC0 1.0). The mark is a
/// GitHub trademark, used only to label links to GitHub.
struct GitHubMark: Shape {
    private static let unitPath = SVGPathParser.path(from: "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12")

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return Self.unitPath.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        )
    }
}
