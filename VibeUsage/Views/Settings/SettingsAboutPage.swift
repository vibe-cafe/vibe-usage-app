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
            // Ways out to the web sit under the card as plain text links, the
            // way System Settings puts 「关于 Apple ID 与隐私…」 under a group —
            // they are not settings (maintainer 2026-11-20).
            HStack(spacing: 16) {
                SettingsTextLink(title: "vibecafe.ai", url: SettingsLinks.vibeCafe)
                SettingsTextLink(title: "vibe-usage", url: SettingsLinks.cliRepository, showsGitHubMark: true)
                SettingsTextLink(title: "vibe-usage-app", url: SettingsLinks.appRepository, showsGitHubMark: true)
            }
            .padding(.horizontal, 2)
            .padding(.top, 10)
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

/// A small text link in the system link color: no frame, no arrow;
/// underlined with a pointing-hand cursor while hovered. Opens in the default
/// browser.
struct SettingsTextLink: View {
    let title: String
    let url: URL
    var showsGitHubMark = false
    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                if showsGitHubMark {
                    GitHubMark()
                        .fill(style: FillStyle(eoFill: true))
                        .frame(width: 11, height: 11)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .underline(isHovered)
            }
            .font(SettingsTheme.caption)
            .foregroundStyle(Color(nsColor: .linkColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .modifier(LinkCursor())
        .help(url.absoluteString)
        .accessibilityAddTraits(.isLink)
        .accessibilityLabel(showsGitHubMark ? "GitHub \(title)" : title)
    }
}

/// The pointing hand over a link (`pointerStyle(.link)` where available).
private struct LinkCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content.onHover { inside in
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
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
