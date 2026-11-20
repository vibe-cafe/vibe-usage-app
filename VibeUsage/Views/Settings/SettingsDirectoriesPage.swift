import SwiftUI

/// 数据目录（高级）: extra places sync scans besides each tool's default
/// directory. The CLI owns these fields; the page only calls it.
struct SettingsDirectoriesPage: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPageScroll {
            SettingsPageHeader(title: SettingsPage.directories.title, advanced: true)
            SettingsCard {
                SettingsRow {
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
                            .font(.system(size: 12))
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
                        Text(message)
                    }
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.green)
                    .padding(.leading, 14)
                    .padding(.trailing, 12)
                    .padding(.bottom, 11)
                } else if let error = model.codexHomeError {
                    Text(error)
                        .font(SettingsTheme.caption)
                        .foregroundStyle(SettingsTheme.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 14)
                        .padding(.trailing, 12)
                        .padding(.bottom, 11)
                }
            }

            Text("隔离运行时目录")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.text)
                .padding(.horizontal, 2)
                .padding(.top, 16)
                .padding(.bottom, 8)

            SettingsCard {
                ForEach(Array(SettingsModel.extraRootSources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 { SettingsSeparator() }
                    rootGroup(source)
                }
            }
            if let error = model.extraRootsError {
                Text(error)
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .padding(.top, 8)
            }
        }
    }

    private func rootGroup(_ source: (id: String, name: String, provider: ProviderRateLimit.Provider)) -> some View {
        let paths = model.extraRoots[source.id] ?? []
        return VStack(alignment: .leading, spacing: 0) {
            SettingsRow {
                ProviderGlyph(provider: source.provider, size: 16)
                    .foregroundStyle(SettingsTheme.text)
                    .frame(width: 18, height: 18)
                SettingsRowLabel(title: source.name)
                Spacer(minLength: 8)
                if model.editingExtraRoots {
                    SettingsSpinner()
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
                .padding(.leading, 42)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private func pathLine(source: String, path: String) -> some View {
        HStack(spacing: 8) {
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(SettingsTheme.mono)
                .foregroundStyle(SettingsTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 26)
        .background(SettingsTheme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(SettingsTheme.line, lineWidth: 1)
        )
    }
}
