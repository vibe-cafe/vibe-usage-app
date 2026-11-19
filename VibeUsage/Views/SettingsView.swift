import SwiftUI
import ServiceManagement

// MARK: - Manifest

/// The Settings window's categories, in toolbar order. This enum is the only
/// place a category is declared: `SettingsWindowController` builds one toolbar
/// tab per case and `SettingsTabContent` maps each case to its page, so adding
/// a category is one case here plus its page.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case account
    case quota
    case dataSources
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .account: "账号与同步"
        case .quota: "订阅配额"
        case .dataSources: "数据来源"
        case .about: "关于与诊断"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .account: "person.crop.circle"
        case .quota: "gauge.with.dots.needle.50percent"
        case .dataSources: "folder"
        case .about: "info.circle"
        }
    }

    /// Every page has the same size, so switching tabs never resizes the
    /// window.
    static let contentSize = CGSize(width: 620, height: 440)
}

/// Where an open Settings window should point when another surface asks for a
/// specific place (a grey quota tab in the panel opens 订阅配额 on its product).
@MainActor
@Observable
final class SettingsNavigation {
    var quotaProvider: ProviderRateLimit.Provider?
}

/// Maps each manifest case to its page.
struct SettingsTabContent: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettingsView()
            case .account: AccountSettingsView()
            case .quota: QuotaSettingsView()
            case .dataSources: DataSourceSettingsView()
            case .about: AboutSettingsView()
            }
        }
        .frame(width: SettingsTab.contentSize.width, height: SettingsTab.contentSize.height)
    }
}

// MARK: - 通用

/// How the app behaves outside this window: startup, Dock, and the menu-bar
/// title. Appearance settings belong here too once they exist.
struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var autoStartEnabled = false
    @State private var hasLoaded = false

    var body: some View {
        Form {
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
            } footer: {
                Text("Dock 显示在关闭设置窗口后生效。")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Read once per window, as the single-page form did: re-reading on
            // every tab switch could flip the switch back and re-run
            // `setAutoStart` through `onChange`.
            guard !hasLoaded else { return }
            hasLoaded = true
            autoStartEnabled = SMAppService.mainApp.status == .enabled
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
}

// MARK: - 账号与同步

/// Account key plus sync health. 「上次同步」 is a trailing detail of the
/// status, so it rides along as a caption instead of costing a full row.
struct AccountSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var apiKeyDisplay = ""
    @State private var isRelinking = false
    @State private var relinkUserCode: String?
    @State private var relinkError: String?
    @State private var relinkTask: Task<Void, Never>?

    var body: some View {
        Form {
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

                LabeledContent("同步状态") {
                    VStack(alignment: .trailing, spacing: 2) {
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

                        if let lastSync = appState.lastSyncTime {
                            Text("上次同步 \(Formatters.formatRelativeTime(lastSync))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadAPIKey() }
        // 「重置配置」 lives on the 关于与诊断 page and removes the config file;
        // re-reading it here keeps this row in step with that and with relinks.
        .onChange(of: appState.isConfigured) { _, _ in loadAPIKey() }
    }

    private func loadAPIKey() {
        if let key = ConfigManager.load()?.apiKey {
            if key.count > 12 {
                apiKeyDisplay = "\(key.prefix(8))...\(key.suffix(4))"
            } else {
                apiKeyDisplay = key
            }
        } else {
            apiKeyDisplay = "未配置"
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
            device = try await requestDeviceCode(baseURL: baseURL, clientName: "\(AppConfig.displayName).app", hostname: hostname)
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
                loadAPIKey()
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
}

// MARK: - 数据来源

/// Extra directories sync scans besides each tool's default one. The CLI owns
/// both fields (`CLIBridge` shells out), so this page only edits through it.
struct DataSourceSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var codexExtraHome = ""
    @State private var isSavingCodexHome = false
    @State private var codexHomeMessage: String?
    @State private var codexHomeError: String?
    @State private var extraRoots: CLIBridge.ExtraRoots = [:]
    @State private var extraRootsError: String?
    @State private var editingExtraRoots = false
    @State private var hasLoaded = false

    private let extraRootSources = [
        (id: "codex", name: "Codex"),
        (id: "grok", name: "Grok"),
        (id: "antigravity", name: "Antigravity / AGY"),
    ]

    var body: some View {
        Form {
            codexHomeSection
            isolatedRuntimeRootSection
        }
        .formStyle(.grouped)
        .onAppear {
            // Once per window, like the single-page form: a tab switch must not
            // overwrite a path the user is still typing.
            guard !hasLoaded else { return }
            hasLoaded = true
            codexExtraHome = ConfigManager.load()?.codexExtraHome ?? ""
            Task { await loadExtraRoots() }
        }
    }

    private var codexHomeSection: some View {
        Section {
            TextField("额外 Codex Home", text: $codexExtraHome, prompt: Text("路径"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
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
        } header: {
            Text("额外 Codex Home")
        } footer: {
            Text("默认的 ~/.codex 仍会统计；留空并保存即移除。")
                .font(.caption)
        }
    }

    private var isolatedRuntimeRootSection: some View {
        Section {
            ForEach(extraRootSources, id: \.id) { source in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(source.name)
                        Spacer()
                        Button("添加目录…") {
                            chooseExtraRoot(source: source.id, name: source.name)
                        }
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
            Text("Multica 等隔离目录；默认目录仍会统计。")
                .font(.caption)
        }
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
}

// MARK: - 关于与诊断

struct AboutSettingsView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var updaterViewModel: UpdaterViewModel

    @State private var showingResetConfirmation = false
    @State private var isGeneratingDiagnostics = false
    @State private var copiedDiagnosticSummary: String?
    @State private var isDiagnosticSummaryExpanded = false
    #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
    @State private var diagnosticExportMessage: String?
    #endif

    var body: some View {
        Form {
            Section {
                LabeledContent("版本") {
                    HStack(spacing: 8) {
                        Text(versionText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("检查更新") {
                            updaterViewModel.checkForUpdates()
                        }
                        .disabled(!updaterViewModel.canCheckForUpdates)
                    }
                }

                diagnosticSummaryRow
            }

            #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
            testDiagnosticsSection
            #endif

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
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppConfig.version
        return AppConfig.isExternalTest ? "\(version) · 外测" : version
    }

    /// One row, per the terse-copy rule: the button copies a whitelisted
    /// summary (no raw output, paths, keys or account names) and the result
    /// can be expanded to read exactly what was copied.
    @ViewBuilder
    private var diagnosticSummaryRow: some View {
        LabeledContent("诊断信息") {
            Button(isGeneratingDiagnostics ? "正在生成…" : "复制诊断信息") {
                Task { await copyDiagnosticSummary() }
            }
            .disabled(isGeneratingDiagnostics)
        }
        if let copiedDiagnosticSummary {
            DisclosureGroup(isExpanded: $isDiagnosticSummaryExpanded) {
                ScrollView {
                    Text(copiedDiagnosticSummary)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            } label: {
                Text("已复制，可以直接贴到群里")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyDiagnosticSummary() async {
        isGeneratingDiagnostics = true
        defer { isGeneratingDiagnostics = false }
        let summary = await appState.diagnosticSummary()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        copiedDiagnosticSummary = summary
    }

    #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
    private var testDiagnosticsSection: some View {
        Section {
            Button("导出诊断日志…") {
                exportDiagnosticLog()
            }
            if let diagnosticExportMessage {
                Text(diagnosticExportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("测试诊断")
        } footer: {
            Text("仅测试构建可用。日志保存在本机，只包含脱敏后的错误码、Provider、版本与系统信息。")
                .font(.caption)
        }
    }

    private func exportDiagnosticLog() {
        diagnosticExportMessage = nil
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "vibe-usage-diagnostics-\(Int(Date().timeIntervalSince1970)).jsonl"
        panel.prompt = "导出"
        panel.message = "请选择脱敏测试诊断日志的保存位置"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try TestDiagnosticLog.export(to: destination)
            diagnosticExportMessage = "诊断日志已导出"
        } catch {
            diagnosticExportMessage = "导出失败：\(error.localizedDescription)"
        }
    }
    #endif

    /// The 账号与同步 page re-reads the (now removed) config file when
    /// `isConfigured` flips, so its key row follows this reset.
    private func resetConfig() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe-usage/\(AppConfig.configFileName)")
        try? FileManager.default.removeItem(at: configPath)
        // The local sync summaries go with the app's data.
        appState.syncHistory.clear()

        appState.isConfigured = false
        appState.buckets = []
    }
}
