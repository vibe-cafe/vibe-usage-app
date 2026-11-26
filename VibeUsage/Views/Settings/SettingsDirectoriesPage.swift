import SwiftUI

/// 数据目录（高级）: extra places sync scans besides each tool's default
/// directory. The CLI owns these fields; the page only calls it.
struct SettingsDirectoriesPage: View {
    @Environment(SettingsModel.self) private var model
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        @Bindable var model = model
        SettingsPageScroll {
            SettingsPageHeader(title: SettingsPage.directories.title, advanced: true)
            SettingsCard {
                SettingsRow(spacing: theme.isModern ? 8 : 10) {
                    SettingsRowLabel(title: "额外 Codex Home")
                        .fixedSize()
                        .padding(.trailing, 6)
                    SettingsTextField(
                        prompt: "另一个 Codex Home 的路径",
                        text: $model.codexExtraHome,
                        showsClearButton: true
                    )
                    .disabled(model.isSavingCodexHome)
                    .onChange(of: model.codexExtraHome) { _, _ in model.codexHomeDraftChanged() }
                    .help(model.codexExtraHome)
                    Button {
                        model.chooseCodexHome()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: theme.isModern ? 11 : 12, weight: theme.isModern ? .medium : .regular))
                    }
                    .buttonStyle(.settingsSquare)
                    .disabled(model.isSavingCodexHome)
                    .help("选择文件夹…")
                    .accessibilityLabel("选择文件夹…")
                    Button("保存并同步") {
                        Task { await model.saveCodexHome() }
                    }
                    .buttonStyle(.settings)
                    .disabled(!model.canSaveCodexHome)
                }
                if let message = model.codexHomeMessage {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.ok)
                        Text(message)
                    }
                    .font(theme.caption)
                    .foregroundStyle(theme.success)
                    .padding(.leading, theme.isModern ? 0 : 14)
                    .padding(.trailing, theme.isModern ? 0 : 12)
                    .padding(.bottom, theme.isModern ? 9 : 11)
                } else if let error = model.codexHomeError {
                    Text(error)
                        .font(theme.caption)
                        .foregroundStyle(theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, theme.isModern ? 0 : 14)
                        .padding(.trailing, theme.isModern ? 0 : 12)
                        .padding(.bottom, theme.isModern ? 9 : 11)
                }
            }

            SettingsSection(title: "隔离运行时目录") {
                ForEach(Array(SettingsModel.extraRootSources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 { SettingsSeparator() }
                    rootGroup(source)
                }
            }
            if let error = model.extraRootsError {
                Text(error)
                    .font(theme.caption)
                    .foregroundStyle(theme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, theme.isModern ? 16 : 2)
                    .padding(.top, 8)
            }
        }
    }

    private func rootGroup(_ source: (id: String, name: String, provider: ProviderRateLimit.Provider)) -> some View {
        let paths = model.extraRoots[source.id] ?? []
        return VStack(alignment: .leading, spacing: 0) {
            SettingsRow(spacing: theme.isModern ? 0 : 10) {
                ProviderGlyph(provider: source.provider, size: theme.isModern ? 15 : 16)
                    .foregroundStyle(theme.isModern ? theme.ok : theme.text)
                    .frame(width: theme.isModern ? 15 : 18, height: theme.isModern ? 15 : 18)
                    .frame(width: theme.isModern ? 22 : 18, alignment: .leading)
                SettingsRowLabel(title: source.name)
                Spacer(minLength: 8)
                if model.editingExtraRoots {
                    SettingsSpinner()
                        .padding(.trailing, theme.isModern ? 8 : 0)
                }
                Button {
                    model.chooseExtraRoot(source: source.id, name: source.name)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(SettingsIconButtonStyle())
                .disabled(model.editingExtraRoots)
                .help("添加目录…")
                .accessibilityLabel("给 \(source.name) 添加目录…")
            }
            if !paths.isEmpty {
                VStack(spacing: 6) {
                    ForEach(paths, id: \.self) { path in
                        pathLine(source: source.id, path: path)
                    }
                }
                .padding(.leading, theme.isModern ? 22 : 42)
                .padding(.trailing, theme.isModern ? 0 : 12)
                .padding(.bottom, theme.isModern ? 10 : 12)
            }
        }
    }

    /// Classic: the path and its － inside one inset box. Modern: the path in
    /// a field like the panel's, the round － beside it.
    private func pathLine(source: String, path: String) -> some View {
        HStack(spacing: 8) {
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(theme.mono)
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, theme.isModern ? 8 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: theme.isModern ? 24 : nil)
                .background {
                    if theme.isModern {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.inset)
                    }
                }
                .help(path)
            Button {
                Task { await model.removeExtraRoot(source: source, path: path) }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(SettingsIconButtonStyle())
            .disabled(model.editingExtraRoots)
            .help("移除此目录")
            .accessibilityLabel("移除此目录")
        }
        .padding(.leading, theme.isModern ? 0 : 9)
        .padding(.trailing, theme.isModern ? 0 : 4)
        .frame(height: theme.isModern ? nil : 26)
        .background {
            if !theme.isModern {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.inset)
            }
        }
        .overlay {
            if !theme.isModern {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.line, lineWidth: 1)
            }
        }
    }
}
