import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var updaterViewModel: UpdaterViewModel

    @State private var apiKeyDisplay: String = ""
    @State private var autoStartEnabled: Bool = false
    @State private var showingResetConfirmation = false
    @State private var isEditingApiKey = false
    @State private var newApiKey = ""
    @State private var isValidatingKey = false
    @State private var apiKeyError: String?

    var body: some View {
        Form {
            // Sync section
            Section {
                LabeledContent("API Key") {
                    if isEditingApiKey {
                        VStack(alignment: .trailing, spacing: 6) {
                            TextField("", text: $newApiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 220)
                            HStack(spacing: 8) {
                                if let apiKeyError {
                                    Text(apiKeyError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("取消") {
                                    isEditingApiKey = false
                                    newApiKey = ""
                                    apiKeyError = nil
                                }
                                .font(.caption)
                                Button("保存") {
                                    Task { await validateAndUpdateKey() }
                                }
                                .font(.caption)
                                .disabled(newApiKey.isEmpty || !newApiKey.hasPrefix("vbu_") || isValidatingKey)
                            }
                            if isValidatingKey {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text(apiKeyDisplay)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Color(white: 0.5))

                            Button("修改") {
                                newApiKey = ""
                                apiKeyError = nil
                                isEditingApiKey = true
                            }
                            .font(.caption)
                        }
                    }
                }

                LabeledContent("状态") {
                    HStack(spacing: 4) {
                        switch appState.syncStatus {
                        case .idle:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("正常")
                        case .syncing:
                            ProgressView()
                                .controlSize(.small)
                            Text("同步中...")
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("同步成功")
                        case .error(let msg):
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(msg)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                }

                if let lastSync = appState.lastSyncTime {
                    LabeledContent("上次同步") {
                        Text(Formatters.formatRelativeTime(lastSync))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("同步")
            }

            // Menu bar display
            Section {
                Toggle("菜单栏显示费用", isOn: Binding(
                    get: { appState.showCostInMenuBar },
                    set: { appState.showCostInMenuBar = $0 }
                ))
                .tint(.green)
                Toggle("菜单栏显示 Token", isOn: Binding(
                    get: { appState.showTokensInMenuBar },
                    set: { appState.showTokensInMenuBar = $0 }
                ))
                .tint(.green)
            } header: {
                Text("菜单栏")
            } footer: {
                Text("在菜单栏图标旁显示费用和 Token 用量")
                    .font(.caption)
            }

            // Auto-start + general
            Section {
                Toggle("开机自启动", isOn: $autoStartEnabled)
                    .tint(.green)
                    .onChange(of: autoStartEnabled) { _, newValue in
                        setAutoStart(newValue)
                    }
            } header: {
                Text("通用")
            }

            // About & Updates
            Section {
                LabeledContent("版本") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppConfig.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("检查更新") {
                    updaterViewModel.checkForUpdates()
                }
                .disabled(!updaterViewModel.canCheckForUpdates)
            } header: {
                Text("关于")
            }

            // Danger zone
            Section {
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    Text("重置配置")
                }
                .confirmationDialog("确定要重置配置吗？", isPresented: $showingResetConfirmation) {
                    Button("重置", role: .destructive) {
                        resetConfig()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("这将清除 API Key 并停止自动同步。")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
        .onAppear {
            loadSettings()
        }
    }

    // MARK: - Private

    private func loadSettings() {
        if let config = ConfigManager.load(), let key = config.apiKey {
            if key.count > 12 {
                apiKeyDisplay = "\(key.prefix(8))...\(key.suffix(4))"
            } else {
                apiKeyDisplay = key
            }
        } else {
            apiKeyDisplay = "未配置"
        }

        autoStartEnabled = SMAppService.mainApp.status == .enabled
    }

    private func setAutoStart(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to set auto-start: \(error)")
        }
    }

    private func validateAndUpdateKey() async {
        apiKeyError = nil
        isValidatingKey = true
        defer { isValidatingKey = false }

        debugLog("[Settings] Validating key: \(newApiKey.prefix(12))... against \(AppConfig.defaultApiUrl)")
        let client = APIClient(baseURL: AppConfig.defaultApiUrl, apiKey: newApiKey)
        do {
            let response = try await client.validateKeyAndFetch()
            debugLog("[Settings] Key valid! Saving config...")
            appState.configure(apiKey: newApiKey, apiUrl: AppConfig.defaultApiUrl)
            appState.buckets = response.buckets
            appState.hasAnyData = response.hasAnyData
            isEditingApiKey = false
            newApiKey = ""
            loadSettings()
        } catch let error as APIClient.APIError {
            debugLog("[Settings] APIError: \(error)")
            if case .unauthorized = error {
                apiKeyError = "API Key \u{65E0}\u{6548}"
            } else {
                apiKeyError = "\u{7F51}\u{7EDC}\u{9519}\u{8BEF}: \(error.localizedDescription)"
            }
        } catch {
            debugLog("[Settings] Error: \(error)")
            apiKeyError = "\u{9A8C}\u{8BC1}\u{5931}\u{8D25}: \(error.localizedDescription)"
        }
    }

    private func resetConfig() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe-usage/\(AppConfig.configFileName)")
        try? FileManager.default.removeItem(at: configPath)

        appState.isConfigured = false
        appState.buckets = []
        apiKeyDisplay = "未配置"
    }
}
