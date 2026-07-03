import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var updaterViewModel: UpdaterViewModel

    @State private var apiKeyDisplay: String = ""
    @State private var autoStartEnabled: Bool = false
    @State private var showingResetConfirmation = false
    @State private var isRelinking = false
    @State private var relinkUserCode: String?
    @State private var relinkError: String?
    @State private var relinkTask: Task<Void, Never>?

    var body: some View {
        Form {
            // Sync section
            Section {
                LabeledContent("API Key") {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(apiKeyDisplay)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Color(white: 0.5))

                            Button(isRelinking ? "等待确认…" : "重新链接") {
                                relinkTask = Task { await relink() }
                            }
                            .font(.caption)
                            .disabled(isRelinking)

                            if isRelinking {
                                Button("取消") {
                                    cancelRelink()
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        if let relinkUserCode {
                            Text("验证码: \(relinkUserCode)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if let relinkError {
                            Text(relinkError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
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

            // Subscription quota monitoring
            Section {
                Toggle("Codex 订阅配额监控", isOn: Binding(
                    get: { appState.codexRateLimitEnabled },
                    set: { newValue in
                        Task { await appState.setCodexRateLimitEnabled(newValue) }
                    }
                ))
                .tint(.green)

                Toggle("Claude Code 订阅配额监控", isOn: Binding(
                    get: { appState.claudeRateLimitEnabled },
                    set: { newValue in
                        Task { await appState.setClaudeRateLimitEnabled(newValue) }
                    }
                ))
                .tint(.green)
            } header: {
                Text("订阅配额")
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

                Toggle("在 Dock 中显示", isOn: Binding(
                    get: { appState.showInDock },
                    set: { appState.showInDock = $0 }
                ))
                .tint(.green)
            } header: {
                Text("通用")
            } footer: {
                Text("关闭设置窗口后生效")
                    .font(.caption)
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
        .frame(width: 420, height: 460)
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

    private func relink() async {
        relinkError = nil
        relinkUserCode = nil
        isRelinking = true
        defer { isRelinking = false }

        let baseURL = AppConfig.defaultApiUrl
        let hostname = Host.current().localizedName?.replacingOccurrences(of: ".local", with: "")
        let device: DeviceCodeResponse
        do {
            device = try await requestDeviceCode(baseURL: baseURL, clientName: "Vibe Usage.app", hostname: hostname)
        } catch {
            relinkError = "无法连接服务端：\(error.localizedDescription)"
            return
        }

        relinkUserCode = device.userCode
        if let url = URL(string: device.verificationUriComplete) {
            NSWorkspace.shared.open(url)
        }

        let intervalNs = UInt64(max(device.interval, 1)) * 1_000_000_000
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))

        while Date() < deadline {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: intervalNs)
            if Task.isCancelled { return }
            let res: DevicePollResponse
            do {
                res = try await pollDeviceCode(baseURL: baseURL, deviceCode: device.deviceCode)
            } catch {
                continue
            }
            if let apiKey = res.apiKey {
                appState.configure(apiKey: apiKey, apiUrl: res.apiUrl ?? baseURL)
                await appState.fetchUsageData()
                relinkUserCode = nil
                loadSettings()
                return
            }
            switch res.error {
            case "authorization_pending", nil:
                continue
            case "access_denied":
                relinkError = DeviceFlowError.denied.localizedDescription
                relinkUserCode = nil
                return
            case "expired_token":
                relinkError = DeviceFlowError.expired.localizedDescription
                relinkUserCode = nil
                return
            default:
                relinkError = "服务端返回未知错误：\(res.error ?? "unknown")"
                relinkUserCode = nil
                return
            }
        }
        relinkError = DeviceFlowError.expired.localizedDescription
        relinkUserCode = nil
    }

    /// Abort an in-flight re-link so the user can start over immediately rather
    /// than waiting out the 15-minute timeout. The cancelled task returns at its
    /// next checkpoint; its `defer` clears `isRelinking`.
    private func cancelRelink() {
        relinkTask?.cancel()
        relinkTask = nil
        relinkUserCode = nil
        relinkError = nil
        isRelinking = false
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
