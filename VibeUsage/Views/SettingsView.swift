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
    @State private var zCodeAPIKey = ""
    @State private var isSavingZCodeAPIKey = false
    @State private var zCodeAPIKeyMessage: String?
    @State private var zCodeAPIKeyError: String?
    @State private var isQuotaSourcesExpanded = false
    @State private var isCodexHomeExpanded = false
    @State private var isIsolatedRootsExpanded = false
    @State private var isZCodeExpanded = false
    #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
    @State private var diagnosticExportMessage: String?
    #endif

    private let extraRootSources = [
        (id: "codex", name: "Codex"),
        (id: "grok", name: "Grok"),
        (id: "antigravity", name: "Antigravity / AGY"),
    ]

    var body: some View {
        Form {
            syncSection
            quotaSection
            generalSection
            dataDirectorySection

            #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
            diagnosticsSection
            #endif

            aboutSection
            resetSection
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 460)
        .onAppear {
            loadSettings()
            Task { await loadExtraRoots() }
        }
    }

    // MARK: - Sections

    /// The subscriptions the panel tracks. Every product is a plain switch, so
    /// the section stays flat; only ZCode (the one product that needs a key)
    /// owns a row that opens, and it sits last.
    private var quotaSection: some View {
        Section {
            ForEach(appState.quotaProducts.filter { $0.provider != .zCode }) { product in
                Toggle(isOn: quotaSelectionBinding(product.provider)) {
                    HStack(alignment: .top, spacing: 8) {
                        ProviderIcon(provider: product.provider)
                            .frame(width: 14, height: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.displayName)
                            Text(appState.quotaProductStatusText(product))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if product.provider == .claudeCode,
                               appState.claudeUsesDesktopBundledCLI {
                                Text("数据来源：Claude Desktop")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .tint(.green)
                .disabled(quotaToggleDisabled(product.provider))
            }

            if let zCodeProduct {
                zCodeRow(zCodeProduct)
            }

            DisclosureGroup(isExpanded: $isQuotaSourcesExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("检测状态仅用于推荐，所有产品都可手动选择；未选择的产品不会联网读取配额。")
                    Text("Grok 仅从官方 CLI 普通日志读取结构化订阅配额；Cursor 可单独选择并等待官方配额接口，不读取 Cookie、登录 Token 或其他应用 Keychain。")
                    Text("Kimi Code 使用其官方 CLI 登录。")
                    Text("OpenCode Go 使用 OpenCode CLI 自己的 API Key（只读本机凭据文件，不读取对话内容）；未订阅 Go 的账号只显示未订阅状态。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)

                Button("重新检测本机产品") {
                    appState.rediscoverQuotaProducts()
                }
            } label: {
                Text("数据来源与检测")
            }
        } header: {
            Text("订阅配额（\(appState.selectedQuotaProviders.count)）")
        } footer: {
            Text("选中的产品会在面板中各显示一张卡片。")
                .font(.caption)
        }
    }

    /// The panel's other cards follow the selection order; the Settings list
    /// keeps ZCode last because it is the only product whose row opens a form.
    private var zCodeProduct: QuotaProduct? {
        appState.quotaProducts.first(where: { $0.provider == .zCode })
    }

    /// Collapsed, ZCode is an ordinary product row (chevron + icon + name +
    /// switch). Its key form only exists once the row is opened, so the row
    /// itself never explains a product the user may not use.
    ///
    /// The status line stays `quotaProductStatusText` (the single source of
    /// truth — the panel's selector tooltip prints its full form), shortened
    /// here to the one fact the row can act on. Wording this map does not
    /// recognize passes through untouched instead of being invented.
    static func compactQuotaStatus(_ status: String) -> String {
        if status.contains("已配置") { return "已配置" }
        if status.contains("需配置") || status.contains("未检测到") { return "待配置" }
        return status
    }

    private func zCodeRow(_ product: QuotaProduct) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isZCodeExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isZCodeExpanded ? 90 : 0))
                        ProviderIcon(provider: .zCode)
                            .frame(width: 14, height: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.displayName)
                            Text(Self.compactQuotaStatus(appState.quotaProductStatusText(product)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Toggle("", isOn: quotaSelectionBinding(.zCode))
                    .labelsHidden()
                    .tint(.green)
                    .disabled(quotaToggleDisabled(.zCode))
            }

            if isZCodeExpanded {
                zCodeConfig
            }
        }
    }

    private var zCodeConfig: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("区域", selection: Binding(
                get: { appState.zCodeQuotaRegion },
                set: { region in
                    zCodeAPIKey = ""
                    zCodeAPIKeyMessage = nil
                    zCodeAPIKeyError = nil
                    Task { await appState.setZCodeQuotaRegion(region) }
                }
            )) {
                ForEach(ZCodeQuotaRegion.allCases) { region in
                    Text(region.displayName).tag(region)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isSavingZCodeAPIKey)

            HStack(spacing: 8) {
                SecureField(
                    appState.zCodeAPIKeyConfigured ? "新 Key" : appState.zCodeQuotaRegion.apiKeyName,
                    text: $zCodeAPIKey
                )
                .textFieldStyle(.roundedBorder)
                Button(appState.zCodeAPIKeyConfigured ? "更新" : "保存") {
                    Task { await saveZCodeAPIKey() }
                }
                .disabled(
                    zCodeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSavingZCodeAPIKey
                )
                if appState.zCodeAPIKeyConfigured {
                    Button("移除", role: .destructive) {
                        Task { await removeZCodeAPIKey() }
                    }
                    .disabled(isSavingZCodeAPIKey)
                }
            }

            if let zCodeAPIKeyMessage {
                Text(zCodeAPIKeyMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let zCodeAPIKeyError {
                Text(zCodeAPIKeyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.leading, 22)
        .padding(.bottom, 2)
    }

    /// One binding for every product switch, including ZCode's custom row.
    private func quotaSelectionBinding(_ provider: ProviderRateLimit.Provider) -> Binding<Bool> {
        Binding(
            get: { appState.isQuotaProviderSelected(provider) },
            set: { newValue in
                Task {
                    await appState.setQuotaProductSelected(provider, selected: newValue)
                }
            }
        )
    }

    /// Turning a product off is always allowed; turning one on is accepted for
    /// every catalog product, so a switch only locks for an unknown provider.
    private func quotaToggleDisabled(_ provider: ProviderRateLimit.Provider) -> Bool {
        !appState.isQuotaProviderSelected(provider)
            && !appState.canSelectQuotaProvider(provider)
    }

    /// Menu-bar and startup preferences cover the same subject — how the app
    /// behaves outside this window — so they share one section instead of two
    /// near-identical ones.
    private var generalSection: some View {
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
            Text("常规")
        } footer: {
            Text("Dock 显示在关闭设置窗口后生效。")
                .font(.caption)
        }
    }

    /// Account key plus sync health. The former standalone 「上次同步」 row is a
    /// trailing detail of the status, so it rides along as a caption instead of
    /// costing a full row.
    private var syncSection: some View {
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
        } header: {
            Text("数据同步")
        }
    }

    /// Extra scan directories are a set-once concern. Both former sections
    /// collapse into disclosure rows that still show their state, so no setting
    /// is lost while the page stops paying a screen for it.
    private var dataDirectorySection: some View {
        Section {
            DisclosureGroup(isExpanded: $isCodexHomeExpanded) {
                codexHomeControls
            } label: {
                LabeledContent("额外 Codex Home") {
                    Text(codexExtraHomeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(codexExtraHome)
                }
            }

            DisclosureGroup(isExpanded: $isIsolatedRootsExpanded) {
                isolatedRuntimeRootControls
            } label: {
                LabeledContent("隔离运行时目录") {
                    Text(isolatedRootsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("数据目录（高级）")
        }
    }

    private var codexExtraHomeSummary: String {
        let value = codexExtraHome.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未设置" : value
    }

    private var isolatedRootsSummary: String {
        let count = extraRoots.values.reduce(0) { $0 + $1.count }
        return count == 0 ? "未添加" : "\(count) 个目录"
    }

    private var codexHomeControls: some View {
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

            Text("额外扫描一个 Codex Home；默认的 ~/.codex 仍会保留。留空并保存可移除额外目录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var isolatedRuntimeRootControls: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Text("可为每种工具添加多个 Multica 或其他隔离目录；默认目录仍会照常统计。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("版本") {
                Text(
                    AppConfig.isExternalTest
                        ? "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppConfig.version) · 外测"
                        : (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppConfig.version)
                )
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
    }

    #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
    private var diagnosticsSection: some View {
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
    #endif

    private var resetSection: some View {
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
        } header: {
            Text("危险操作")
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

    private func saveZCodeAPIKey() async {
        isSavingZCodeAPIKey = true
        zCodeAPIKeyMessage = nil
        zCodeAPIKeyError = nil
        defer { isSavingZCodeAPIKey = false }
        do {
            try appState.storeZCodeAPIKey(zCodeAPIKey)
            zCodeAPIKey = ""
            zCodeAPIKeyMessage = "已保存"
            if appState.isQuotaProviderSelected(.zCode) {
                await appState.refreshRateLimit(for: .zCode)
            }
        } catch {
            zCodeAPIKeyError = error.localizedDescription
        }
    }

    private func removeZCodeAPIKey() async {
        isSavingZCodeAPIKey = true
        zCodeAPIKeyMessage = nil
        zCodeAPIKeyError = nil
        defer { isSavingZCodeAPIKey = false }
        do {
            try appState.storeZCodeAPIKey(nil)
            zCodeAPIKey = ""
            zCodeAPIKeyMessage = "已移除"
        } catch {
            zCodeAPIKeyError = error.localizedDescription
        }
    }

    #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
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
