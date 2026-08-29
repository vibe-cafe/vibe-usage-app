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
    @State private var codexExtraHome = ""
    @State private var isSavingCodexHome = false
    @State private var codexHomeMessage: String?
    @State private var codexHomeError: String?
    @State private var extraRoots: CLIBridge.ExtraRoots = [:]
    @State private var extraRootsError: String?
    @State private var editingExtraRoots = false

    private let extraRootSources = [
        (id: "codex", name: "Codex"),
        (id: "grok", name: "Grok"),
        (id: "antigravity", name: "Antigravity / AGY"),
    ]

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

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("额外 Codex Home 路径", text: $codexExtraHome)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSavingCodexHome)

                    HStack {
                        Button("选择文件夹…") {
                            chooseCodexHome()
                        }
                        .disabled(isSavingCodexHome)

                        Spacer()

                        if isSavingCodexHome {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button("保存并同步") {
                            Task { await saveCodexHome() }
                        }
                        .disabled(isSavingCodexHome)
                    }

                    if let codexHomeMessage {
                        Text(codexHomeMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let codexHomeError {
                        Text(codexHomeError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                }
            } header: {
                Text("Codex 数据目录")
            } footer: {
                Text("额外扫描一个 Codex Home；默认的 ~/.codex 仍会保留。留空并保存可移除额外目录。")
                    .font(.caption)
            }

            Section {
                ForEach(extraRootSources, id: \.id) { source in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(source.name)
                            Spacer()
                            Button("添加目录…") {
                                chooseExtraRoot(source: source.id, name: source.name)
                            }
                            .font(.caption)
                            .disabled(editingExtraRoots)
                        }

                        ForEach(extraRoots[source.id] ?? [], id: \.self) { path in
                            HStack(spacing: 8) {
                                Text(path)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(path)
                                Spacer(minLength: 8)
                                Button(role: .destructive) {
                                    Task { await removeExtraRoot(source: source.id, path: path) }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .disabled(editingExtraRoots)
                                .help("移除此目录")
                            }
                        }
                    }
                }

                if editingExtraRoots {
                    ProgressView()
                        .controlSize(.small)
                }
                if let extraRootsError {
                    Text(extraRootsError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            } header: {
                Text("隔离运行时目录")
            } footer: {
                Text("可为每种工具添加多个 Multica 或其他隔离目录；默认目录仍会照常统计。")
                    .font(.caption)
            }

            // Subscription quota monitoring
            Section {
                Toggle("显示 Codex 订阅配额", isOn: Binding(
                    get: { appState.codexRateLimitEnabled },
                    set: { newValue in
                        Task { await appState.setCodexRateLimitEnabled(newValue) }
                    }
                ))
                .tint(.green)

                Toggle(isOn: Binding(
                    get: { appState.claudeRateLimitEnabled },
                    set: { newValue in
                        Task { await appState.setClaudeRateLimitEnabled(newValue) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示 Claude 订阅配额")
                        // Only worth explaining when the numbers come from the
                        // Claude Code copy bundled inside Claude Desktop, which
                        // the user never installed themselves.
                        if appState.claudeUsesDesktopBundledCLI {
                            Text("数据来源：Claude Desktop")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
            Task { await loadExtraRoots() }
        }
    }

    // MARK: - Private

    private func loadSettings() {
        if let config = ConfigManager.load() {
            codexExtraHome = config.codexExtraHome ?? ""
            if let key = config.apiKey {
                if key.count > 12 {
                    apiKeyDisplay = "\(key.prefix(8))...\(key.suffix(4))"
                } else {
                    apiKeyDisplay = key
                }
            } else {
                apiKeyDisplay = "未配置"
            }
        } else {
            codexExtraHome = ""
            apiKeyDisplay = "未配置"
        }

        autoStartEnabled = SMAppService.mainApp.status == .enabled
    }

    private func chooseCodexHome() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "请选择包含 sessions 或 archived_sessions 的 Codex Home"

        let expanded = (codexExtraHome as NSString).expandingTildeInPath
        if !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) {
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        codexExtraHome = url.path
        codexHomeMessage = nil
        codexHomeError = nil
    }

    private func saveCodexHome() async {
        isSavingCodexHome = true
        codexHomeMessage = nil
        codexHomeError = nil
        defer { isSavingCodexHome = false }

        let value = codexExtraHome.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await CLIBridge.configSet(key: "codexExtraHome", value: value)
            codexExtraHome = value
            codexHomeMessage = value.isEmpty ? "已移除额外目录" : "已保存，正在同步"
            await appState.triggerSync()
        } catch {
            codexHomeError = error.localizedDescription
        }
    }

    private func chooseExtraRoot(source: String, name: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "请选择 \(name) 的数据根目录或包含多个隔离 Home 的容器目录"

        panel.begin { response in
            guard response == .OK, let path = panel.url?.path else { return }
            Task { await addExtraRoot(source: source, path: path) }
        }
    }

    private func loadExtraRoots() async {
        do {
            extraRoots = try await CLIBridge.configRoots()
            extraRootsError = nil
        } catch {
            extraRootsError = error.localizedDescription
        }
    }

    private func addExtraRoot(source: String, path: String) async {
        editingExtraRoots = true
        extraRootsError = nil
        defer { editingExtraRoots = false }
        do {
            try await CLIBridge.configAddRoot(source: source, path: path)
            extraRoots = try await CLIBridge.configRoots()
            await appState.triggerSync()
        } catch {
            extraRootsError = error.localizedDescription
        }
    }

    private func removeExtraRoot(source: String, path: String) async {
        editingExtraRoots = true
        extraRootsError = nil
        defer { editingExtraRoots = false }
        do {
            try await CLIBridge.configRemoveRoot(source: source, path: path)
            extraRoots = try await CLIBridge.configRoots()
            await appState.triggerSync()
        } catch {
            extraRootsError = error.localizedDescription
        }
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
