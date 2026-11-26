import SwiftUI
import ServiceManagement

// MARK: - Pages and navigation

/// The five sidebar pages, in the order the maintainer set on 2026-11-19
/// (「常规、订阅配额、数据同步、数据目录（高级）、关于」, 常规 later renamed 通用).
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case quotas
    case sync
    case directories
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .quotas: "订阅配额"
        case .sync: "数据同步"
        case .directories: "数据目录"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "menubar.rectangle"
        case .quotas: "gauge.open.with.lines.needle.33percent"
        case .sync: "arrow.2.circlepath"
        case .directories: "folder"
        case .about: "info.circle"
        }
    }
}

/// Where an entry point wants the window to land.
enum SettingsDestination: Equatable {
    /// The popover's 「设置」: wherever the user was last time.
    case lastPage
    /// The panel's gear (no product) or a grey product tab (that product).
    case quotas(focus: ProviderRateLimit.Provider?)
}

/// Which page is showing, persisted so the window reopens where the user left
/// it (Apple's guidance for settings windows). First launch shows 通用.
///
/// `settingsLastPage` is a UI-state key in the app's own preferences: it holds
/// a page name only and nothing reads it but this window.
@MainActor
@Observable
final class SettingsNavigation {
    nonisolated static let lastPageKey = "settingsLastPage"

    var page: SettingsPage {
        didSet {
            guard page != oldValue else { return }
            defaults.set(page.rawValue, forKey: Self.lastPageKey)
        }
    }
    /// The product row to flash after arriving from the panel. `focusRequest`
    /// changes on every arrival, so clicking the same tab twice flashes twice.
    private(set) var focusedProvider: ProviderRateLimit.Provider?
    private(set) var focusRequest = 0
    /// Product rows open in the 订阅配额 table (only ZCode has a body today).
    var expandedProviders: Set<ProviderRateLimit.Provider> = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.page = Self.restoredPage(defaults: defaults)
    }

    nonisolated static func restoredPage(defaults: UserDefaults) -> SettingsPage {
        defaults.string(forKey: lastPageKey).flatMap(SettingsPage.init(rawValue:)) ?? .general
    }

    func open(_ destination: SettingsDestination, zCodeKeyConfigured: Bool, cursorNeedsSignIn: Bool = false) {
        guard case .quotas(let provider) = destination else { return }
        page = .quotas
        guard let provider else { return }
        focusedProvider = provider
        focusRequest &+= 1
        if Self.opensConfiguration(
            on: provider, zCodeKeyConfigured: zCodeKeyConfigured, cursorNeedsSignIn: cursorNeedsSignIn
        ) {
            expandedProviders.insert(provider)
        }
    }

    /// A fresh window starts with every row collapsed and nothing to flash.
    func resetTransientState() {
        expandedProviders = []
        focusedProvider = nil
    }

    /// Arriving from the panel's grey ZCode tab while ZCode still has no key
    /// opens its row, because the key is the only thing standing between the
    /// user and a card. (Turning the switch on does *not* open it.) Cursor's
    /// row opens the same way while it needs a sign-in (its card's
    /// 「需要登录 Cursor」 / 「Cursor 登录已失效」 lead here).
    nonisolated static func opensConfiguration(
        on provider: ProviderRateLimit.Provider,
        zCodeKeyConfigured: Bool,
        cursorNeedsSignIn: Bool = false
    ) -> Bool {
        switch provider {
        case .zCode: !zCodeKeyConfigured
        case .cursor: cursorNeedsSignIn
        default: false
        }
    }
}

// MARK: - Display rules (pure, unit-tested)

/// The 订阅配额 table's 状态 column: local detection, or what is missing.
enum SettingsQuotaStatus {
    private static func failureText(_ failure: ProviderRateLimit.LiveFailure, provider: ProviderRateLimit.Provider) -> String {
        switch failure {
        case .credentialsNotFound: return provider == .zCode ? "需 Key" : "需登录"
        // AGY reports "sign in" the same way whether it was never signed in or lapsed.
        case .credentialsRejected: return provider == .zCode ? "Key 无效" : provider == .antigravity ? "需登录" : "已失效"
        case .credentialsExpired: return provider == .opencodeGo ? "需打开" : "已失效"
        case .programNotFound, .claudeBinaryNotFound: return "未安装"
        case .programOutdated: return "需升级"
        case .claudeBlockedByPolicy: return "已禁止"
        case .egressRegionUnsupported, .egressUnconfirmed, .proxyNotDetected, .proxyUnsupported: return "已暂停"
        case .claudeTimedOut, .cliTimedOut, .endpointTimedOut: return "超时"
        case .endpointUnreachable: return "连不上"
        case .endpointHTTPStatus: return "接口报错"
        case .endpointUnrecognized, .cliUnrecognizedOutput: return "数据异常"
        case .credentialsUnreadable, .localRecordUnreadable: return "读不了"
        case .credentialsEncrypted: return "不支持"
        case .loginRefreshFailed: return "续期失败"
        case .signInRequired: return "需登录"
        case .signInExpired: return "已失效"
        case .programNoAnswer, .claudeNoWindows, .claudeNoResponse: return "无响应"
        case .claudeLaunchFailed: return "启动失败"
        case .cliRuntimeMissing: return "缺 Node"
        case .cliFailed, .cliSchemaMismatch, .cliNoResult: return "CLI 出错"
        case .cliReportedFailure: return "失败"
        }
    }

    /// `cursorSignInEnded`: Cursor ended the sign-in Vibe Usage keeps; the
    /// row says so even while its card is off.
    static func status(
        for product: QuotaProduct,
        zCodeKeyConfigured: Bool,
        warningSnapshot: ProviderRateLimit? = nil,
        cursorSignInEnded: Bool = false
    ) -> (kind: SettingsStatusKind, text: String) {
        if let snapshot = warningSnapshot {
            let reason = snapshot.liveFailure.map { failureText($0, provider: product.provider) }
            switch snapshot.status {
            case .unauthorized:
                if let reason { return (.warning, reason) }
                if product.provider == .zCode { return (.warning, zCodeKeyConfigured ? "Key 无效" : "需 Key") }
                return (.warning, product.provider == .opencodeGo ? "需登录" : "已失效")
            case .noData:
                switch snapshot.emptyReason {
                case .notEntitled: return (.warning, "未订阅")
                case .sessionWithoutPlanLimits:
                    return (.warning, product.provider == .claudeCode ? "未用订阅登录" : "不适用")
                case .nonessentialTrafficDisabled: return (.warning, "已禁止")
                case .limitReached: return (.warning, "已用满")
                case .noWindow: return (.warning, "无窗口")
                case .periodEnded: return (.warning, "待更新")
                case .noLocalRecord: return (.warning, "无记录")
                case nil: return (.warning, reason ?? (snapshot.fetchedAt == nil ? "未读取" : "无数据"))
                }
            case .retryableError: return (.warning, reason ?? "失败")
            case .error: return (.error, "出错")
            case .disabled: return (.warning, "未启用")
            case .ok:
                if snapshot.liveFailure?.isNetworkPause == true { return (.warning, "已暂停") }
            }
        }
        if product.provider == .zCode, product.availability == .ready, !zCodeKeyConfigured {
            return (.warning, "需 Key")
        }
        if product.provider == .cursor, cursorSignInEnded {
            return (.warning, "已失效")
        }
        return (product.isDetected ? .ok : .none, product.statusText)
    }
}

/// The 数据同步 page's 同步 row and the sidebar dot.
enum SettingsSyncSummary {
    struct Line: Equatable {
        var kind: SettingsStatusKind?
        var text: String
        var isSpinning = false
    }

    static func line(
        status: SyncStatus,
        isConfigured: Bool,
        lastSync: Date?,
        now: Date = Date()
    ) -> Line {
        guard isConfigured else { return Line(kind: nil, text: "—") }
        switch status {
        case .syncing:
            return Line(kind: nil, text: "同步中…", isSpinning: true)
        case .error(let message):
            return Line(kind: .error, text: message)
        case .idle, .success:
            guard let lastSync else { return Line(kind: .ok, text: "正常") }
            return Line(kind: .ok, text: "正常 · \(Formatters.formatRelativeTime(lastSync, relativeTo: now))")
        }
    }

    /// Red after a failed sync; nothing otherwise (working, syncing, not
    /// linked) — the sidebar only speaks up when something needs attention.
    /// Follows the 同步 row: once the account is unlinked or reset the row
    /// shows 「—」, so a stale failure from before no longer counts.
    static func sidebarDot(status: SyncStatus, isConfigured: Bool) -> SettingsStatusKind? {
        guard isConfigured else { return nil }
        if case .error = status { return .error }
        return nil
    }

    /// One bar per recorded sync, oldest on the left; `true` is a success.
    /// The store keeps the newest 10, newest first.
    static func bars(from records: [SyncRecord]) -> [Bool] {
        records.prefix(SyncHistoryStore.limit).reversed().map { $0.result == .success }
    }
}

/// Reordering inside the 订阅配额 table. Drops stay inside the dragged
/// product's own group (on / off), matching the panel's strip; the result is
/// the `before:` argument of `AppState.moveQuotaProduct`.
enum QuotaReorder {
    enum Target: Equatable {
        /// Insert before this product; `nil` = the end of the dragged group.
        case before(ProviderRateLimit.Provider?)
        /// Not a valid drop (the other group, or nothing is being dragged).
        case reject
    }

    static func target(
        dragged: ProviderRateLimit.Provider?,
        row: ProviderRateLimit.Provider,
        dropAfter: Bool,
        enabled: [ProviderRateLimit.Provider],
        disabled: [ProviderRateLimit.Provider]
    ) -> Target {
        guard let dragged else { return .reject }
        let group = enabled.contains(row) ? enabled : disabled
        guard group.contains(dragged), let index = group.firstIndex(of: row) else { return .reject }
        guard dropAfter else { return .before(row) }
        let next = group.index(after: index)
        return .before(next < group.endIndex ? group[next] : nil)
    }
}

/// 额外 Codex Home: 「保存并同步」 is dimmed only when there is nothing to
/// save or remove — the field is empty and nothing is saved. Clearing a saved
/// path (the field's ×) and saving still removes it, as before.
enum CodexHomeDraft {
    static func canSave(draft: String, saved: String) -> Bool {
        !(trimmed(draft).isEmpty && trimmed(saved).isEmpty)
    }

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Window state and actions

/// Everything the five pages edit, kept per window so switching pages never
/// drops an in-flight re-link, a half-typed key or a save result. A new
/// window starts from a fresh model, reloaded from disk like the old page did
/// on appear.
@MainActor
@Observable
final class SettingsModel {
    let appState: AppState

    // 数据同步
    var apiKeyDisplay = ""
    private(set) var hasAPIKey = false
    var isRelinking = false
    var relinkUserCode: String?
    var relinkError: String?
    private var relinkTask: Task<Void, Never>?

    // 通用
    var autoStartEnabled = false

    // 数据目录
    var codexExtraHome = ""
    private(set) var savedCodexExtraHome = ""
    var isSavingCodexHome = false
    var codexHomeMessage: String?
    var codexHomeError: String?
    var extraRoots: CLIBridge.ExtraRoots = [:]
    var extraRootsError: String?
    var editingExtraRoots = false

    // ZCode
    var zCodeAPIKeyDraft = ""
    var isSavingZCodeAPIKey = false
    var zCodeAPIKeyError: String?
    /// 「更换」 pressed: the saved-key line gives way to the field again.
    var isReplacingZCodeAPIKey = false

    // 关于
    var isGeneratingDiagnostics = false
    var copiedDiagnosticSummary: String?
    #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
    var diagnosticExportMessage: String?
    #endif

    static let extraRootSources: [(id: String, name: String, provider: ProviderRateLimit.Provider)] = [
        ("codex", "Codex", .codex),
        ("grok", "Grok", .grok),
        ("antigravity", "Antigravity / AGY", .antigravity),
    ]

    init(appState: AppState) {
        self.appState = appState
    }

    func load() {
        let config = ConfigManager.load()
        codexExtraHome = config?.codexExtraHome ?? ""
        hasAPIKey = config?.apiKey != nil
        apiKeyDisplay = config?.apiKey.map(Self.maskedKey) ?? "未配置"
        savedCodexExtraHome = codexExtraHome
        autoStartEnabled = SMAppService.mainApp.status == .enabled
        Task { await loadExtraRoots() }
    }

    static func maskedKey(_ key: String) -> String {
        key.count > 12 ? "\(key.prefix(8))...\(key.suffix(4))" : key
    }

    // MARK: 通用

    func setAutoStart(_ enabled: Bool) {
        autoStartEnabled = enabled
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to set auto-start: \(error)")
            autoStartEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: 数据同步

    func startRelink() {
        relinkTask = Task { await relink() }
    }

    private func relink() async {
        relinkError = nil
        relinkUserCode = nil
        isRelinking = true
        defer { isRelinking = false }

        appState.reloadConfig()
        let server = appState.usageServer
        let hostname = Host.current().localizedName?.replacingOccurrences(of: ".local", with: "")
        let device: DeviceCodeResponse
        do {
            device = try await requestDeviceCode(server: server, clientName: "\(AppConfig.displayName).app", hostname: hostname)
        } catch {
            relinkError = "无法连接服务端：\(error.localizedDescription)"
            return
        }

        relinkUserCode = device.userCode
        if let url = server.verificationURL(device.verificationUriComplete) {
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
                res = try await pollDeviceCode(server: server, deviceCode: device.deviceCode)
            } catch {
                continue
            }
            if let apiKey = res.apiKey {
                appState.configure(apiKey: apiKey, server: res.linkedServer(fallingBackTo: server))
                await appState.fetchUsageData()
                relinkUserCode = nil
                load()
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
    func cancelRelink() {
        relinkTask?.cancel()
        relinkTask = nil
        relinkUserCode = nil
        relinkError = nil
        isRelinking = false
    }

    func resetConfig() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe-usage/\(AppConfig.configFileName)")
        try? FileManager.default.removeItem(at: configPath)
        // The local sync summaries go with the app's data.
        appState.syncHistory.clear()

        appState.applyConfig(nil)
        apiKeyDisplay = "未配置"
        hasAPIKey = false
    }

    // MARK: 数据目录

    var canSaveCodexHome: Bool {
        !isSavingCodexHome && CodexHomeDraft.canSave(draft: codexExtraHome, saved: savedCodexExtraHome)
    }

    func chooseCodexHome() {
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

    func saveCodexHome() async {
        isSavingCodexHome = true
        codexHomeMessage = nil
        codexHomeError = nil
        defer { isSavingCodexHome = false }

        let value = CodexHomeDraft.trimmed(codexExtraHome)
        do {
            try await CLIBridge.configSet(key: "codexExtraHome", value: value)
            codexExtraHome = value
            savedCodexExtraHome = value
            codexHomeMessage = value.isEmpty ? "已移除额外目录" : "已保存，正在同步"
            await appState.triggerSync()
        } catch {
            codexHomeError = error.localizedDescription
        }
    }

    func codexHomeDraftChanged() {
        codexHomeMessage = nil
        codexHomeError = nil
    }

    func chooseExtraRoot(source: String, name: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "请选择 \(name) 的数据根目录或包含多个隔离 Home 的容器目录"

        panel.begin { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            Task { @MainActor in await self?.addExtraRoot(source: source, path: path) }
        }
    }

    func loadExtraRoots() async {
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

    func removeExtraRoot(source: String, path: String) async {
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

    // MARK: ZCode

    /// The saved-key line, unless 「更换」 asked for the field again.
    var showsSavedZCodeKey: Bool {
        appState.zCodeAPIKeyConfigured && !isReplacingZCodeAPIKey
    }

    var canSaveZCodeAPIKey: Bool {
        !isSavingZCodeAPIKey && !zCodeAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setZCodeRegion(_ region: ZCodeQuotaRegion) {
        guard region != appState.zCodeQuotaRegion else { return }
        zCodeAPIKeyDraft = ""
        zCodeAPIKeyError = nil
        isReplacingZCodeAPIKey = false
        Task { await appState.setZCodeQuotaRegion(region) }
    }

    func beginReplacingZCodeAPIKey() {
        zCodeAPIKeyDraft = ""
        zCodeAPIKeyError = nil
        isReplacingZCodeAPIKey = true
    }

    func cancelReplacingZCodeAPIKey() {
        zCodeAPIKeyDraft = ""
        zCodeAPIKeyError = nil
        isReplacingZCodeAPIKey = false
    }

    /// Saving never turns the ZCode switch on; it only refreshes a card the
    /// user already enabled.
    func saveZCodeAPIKey() async {
        isSavingZCodeAPIKey = true
        zCodeAPIKeyError = nil
        defer { isSavingZCodeAPIKey = false }
        do {
            try appState.storeZCodeAPIKey(zCodeAPIKeyDraft)
            zCodeAPIKeyDraft = ""
            isReplacingZCodeAPIKey = false
            if appState.isQuotaProviderSelected(.zCode) {
                // The card shows its own loading state; the controls are free
                // again at once (after a login launch the read may wait up to
                // two minutes for the proxy).
                let appState = appState
                Task { await appState.refreshRateLimit(for: .zCode) }
            }
        } catch {
            zCodeAPIKeyError = error.localizedDescription
        }
    }

    /// Removing the key also turns the ZCode switch off (`storeZCodeAPIKey`).
    func removeZCodeAPIKey() {
        isSavingZCodeAPIKey = true
        zCodeAPIKeyError = nil
        defer { isSavingZCodeAPIKey = false }
        do {
            try appState.storeZCodeAPIKey(nil)
            zCodeAPIKeyDraft = ""
            isReplacingZCodeAPIKey = false
        } catch {
            zCodeAPIKeyError = error.localizedDescription
        }
    }

    // MARK: 关于

    func copyDiagnosticSummary() async {
        isGeneratingDiagnostics = true
        defer { isGeneratingDiagnostics = false }
        let summary = await appState.diagnosticSummary()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        copiedDiagnosticSummary = summary
    }

    #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
    func exportDiagnosticLog() {
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
}
