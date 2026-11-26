import AppKit
import SwiftUI
import Testing
@testable import VibeUsage

/// Off-screen renders of the Settings window, one PNG per page and state, for
/// design review. Opt-in:
///
///     VIBE_USAGE_RENDER_SETTINGS=<dir> swift test --filter SettingsRenderTests
///
/// Fixtures only: in-memory preferences, a fake Keychain and CLI, no shared
/// config, no desktop picture (the preview draws its fallback gradient), no
/// network. Each window is drawn with `NSHostingView.cacheDisplay`, so text
/// fields and scroll views render like the real window.
@MainActor
@Suite(.serialized)
struct SettingsRenderTests {
    nonisolated static let outputDirectory = ProcessInfo.processInfo.environment["VIBE_USAGE_RENDER_SETTINGS"]

    @Test(.enabled(if: outputDirectory != nil))
    func renderEveryPageInBothStyles() async throws {
        let directory = URL(fileURLWithPath: Self.outputDirectory!, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.applicationIconImage = Self.appIcon

        for style in [InterfaceStyle.classic, .modern] {
            for state in SettingsRenderState.all {
                let fixture = SettingsRenderFixture(style: style, state: state)
                defer { fixture.cleanUp() }
                await fixture.prepare()
                let name = "\(style.rawValue)-\(state.name)"
                try Self.render(fixture.window, size: CGSize(width: 700, height: state.height),
                                to: directory.appendingPathComponent("\(name).png"))
            }
        }
    }

    private static var appIcon: NSImage? {
        let icon = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VibeUsage/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png")
        return NSImage(contentsOf: icon)
    }

    static func render<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        window.contentView = nil
    }
}

/// One page in one state.
struct SettingsRenderState: Sendable {
    let name: String
    let page: SettingsPage
    var height: CGFloat = 460
    var selected: [ProviderRateLimit.Provider] = [.claudeCode, .codex, .cursor, .grok]
    var expanded: Set<ProviderRateLimit.Provider> = []
    var zCodeKey = false
    var cursor: CursorFixture = .signedOut
    var warnings = false
    var styleRow = false
    var showTokens = false
    /// Opens the egress menu once laid out (modern; classic draws the system pop-up).
    var menuOpen = false
    var apply: (@MainActor @Sendable (SettingsModel, AppState) -> Void)?

    enum CursorFixture: Sendable { case signedOut, waiting, signedIn, expired, failed }

    static let all: [SettingsRenderState] = [
        // 通用 (138a, 139)
        .init(name: "general", page: .general),
        .init(name: "general-usage", page: .general) { _, appState in
            appState.isConfigured = true
        },
        .init(name: "general-both", page: .general, showTokens: true),
        .init(name: "general-usage-both", page: .general, showTokens: true) { _, appState in
            appState.isConfigured = true
        },
        .init(name: "general-style-row", page: .general, styleRow: true),
        // 订阅配额 (138b, 138f, 140)
        .init(name: "quotas", page: .quotas, height: 560),
        .init(name: "quotas-zcode", page: .quotas, height: 600, expanded: [.zCode]),
        .init(name: "quotas-zcode-saved", page: .quotas, height: 600, expanded: [.zCode], zCodeKey: true),
        .init(name: "quotas-zcode-error", page: .quotas, height: 620, expanded: [.zCode]) { model, _ in
            model.zCodeAPIKeyDraft = "fixture-key-0000000000"
            model.zCodeAPIKeyError = "无法访问钥匙串（-25308）"
        },
        .init(name: "quotas-cursor", page: .quotas, height: 600, expanded: [.cursor]),
        .init(name: "quotas-cursor-waiting", page: .quotas, height: 620, expanded: [.cursor], cursor: .waiting),
        .init(name: "quotas-cursor-signed-in", page: .quotas, height: 600, expanded: [.cursor], cursor: .signedIn),
        .init(name: "quotas-cursor-expired", page: .quotas, height: 600, expanded: [.cursor], cursor: .expired),
        .init(name: "quotas-cursor-failed", page: .quotas, height: 620, expanded: [.cursor], cursor: .failed),
        .init(name: "quotas-menu", page: .quotas, height: 660, menuOpen: true),
        .init(name: "quotas-menu-short", page: .quotas, height: 560, menuOpen: true),
        .init(name: "quotas-all-on", page: .quotas, height: 560,
              selected: [.claudeCode, .codex, .cursor, .grok, .antigravity, .kimiCode, .zCode, .opencodeGo],
              zCodeKey: true),
        .init(name: "quotas-status", page: .quotas, height: 560,
              selected: [.claudeCode, .codex, .cursor, .grok, .antigravity, .kimiCode], warnings: true),
        // 数据同步 (138c, 141)
        .init(name: "sync", page: .sync) { model, appState in
            Self.linked(model, appState)
        },
        .init(name: "sync-unlinked", page: .sync) { model, _ in
            model.apiKeyDisplay = "未配置"
        },
        .init(name: "sync-relinking", page: .sync) { model, appState in
            Self.linked(model, appState)
            model.isRelinking = true
            model.relinkUserCode = "WDJB-MJHT"
        },
        .init(name: "sync-relink-error", page: .sync) { model, appState in
            Self.linked(model, appState)
            model.relinkError = "验证码已过期，请重新登录。"
        },
        .init(name: "sync-syncing", page: .sync) { model, appState in
            Self.linked(model, appState)
            appState.syncStatus = .syncing
        },
        .init(name: "sync-error", page: .sync) { model, appState in
            Self.linked(model, appState, failures: 2)
            appState.syncStatus = .error("API Key 无效，请重新配置")
        },
        // 数据目录 (138d, 142)
        .init(name: "directories", page: .directories) { model, _ in
            model.extraRoots = ["codex": [Self.home("work/sandbox-a/.codex")]]
        },
        .init(name: "directories-saved", page: .directories) { model, _ in
            model.codexExtraHome = "~/work/sandbox-a/.codex"
            model.codexHomeMessage = "已保存，正在同步"
        },
        .init(name: "directories-error", page: .directories) { model, _ in
            model.codexExtraHome = "~/work/sandbox-a/.codex"
            model.codexHomeError = "CLI 操作超时"
        },
        .init(name: "directories-roots", page: .directories, height: 520) { model, _ in
            model.extraRoots = [
                "codex": [
                    Self.home("work/sandbox-a/.codex"),
                    Self.home("Library/Application Support/agents/workspace-0042/sandbox/profile-3/.codex"),
                ],
                "grok": [Self.home("work/sandbox-a/.grok")],
            ]
        },
        .init(name: "directories-editing", page: .directories) { model, _ in
            model.extraRoots = ["codex": [Self.home("work/sandbox-a/.codex")]]
            model.editingExtraRoots = true
        },
        .init(name: "directories-roots-error", page: .directories) { model, _ in
            model.extraRoots = ["codex": [Self.home("work/sandbox-a/.codex")]]
            model.extraRootsError = "CLI 操作超时"
        },
        // 关于 (138e, 143)
        .init(name: "about", page: .about, height: 600),
        .init(name: "about-copying", page: .about, height: 600) { model, _ in
            model.isGeneratingDiagnostics = true
        },
        .init(name: "about-copied", page: .about, height: 760) { model, _ in
            model.copiedDiagnosticSummary = Self.diagnosticSample
        },
        .init(name: "about-exported", page: .about, height: 620) { model, _ in
            model.diagnosticExportMessage = "诊断日志已导出"
        },
    ]

    @MainActor
    private static func linked(_ model: SettingsModel, _ appState: AppState, failures: Int = 0) {
        model.hasAPIKey = true
        model.apiKeyDisplay = "vbu_k3f9...a41c"
        appState.isConfigured = true
        appState.syncStatus = .success
        let now = Date()
        appState.lastSyncTime = now.addingTimeInterval(-26 * 60)
        for index in 0..<10 {
            // Appended oldest first; the newest `failures` runs failed.
            let failed = index >= 10 - failures
            appState.syncHistory.append(SyncRecord(
                startedAt: now.addingTimeInterval(Double(index - 10) * 1800),
                duration: 4, trigger: .scheduled,
                result: failed ? .failure : .success,
                reason: failed ? .keyRejected : nil
            ))
        }
    }

    private static func home(_ path: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(path)
    }

    static let diagnosticSample = """
    Vibe Usage 诊断报告 v1 · 2026-11-26 14:32（UTC+8）
    环境：macOS 26.1.0 arm64 · App 0.7.6（42）正式版
    运行环境：App 自带 Node 24.22.3
    自带 Node：能启动（24.22.3）
    CLI：启动正常 · 0.14.11 · 启动脚本正常
    账号：已配置 Key · 最近一次同步未被服务器拒绝
    后台：App 定时同步（每 30 分钟）已开启
    订阅配额：Claude 已开启 · 正常
    """
}

/// The app state, model and navigation one render draws from.
@MainActor
final class SettingsRenderFixture {
    private final class MemoryKeys: ZCodeAPIKeyStoring {
        var values: [ZCodeQuotaRegion: String] = [:]
        func load(for region: ZCodeQuotaRegion) throws -> String? { values[region] }
        func store(_ value: String?, for region: ZCodeQuotaRegion) throws { values[region] = value }
    }

    static let order: [ProviderRateLimit.Provider] = [
        .claudeCode, .codex, .cursor, .grok, .antigravity, .kimiCode, .zCode, .opencodeGo,
    ]

    private let suite = "SettingsRender.\(UUID().uuidString)"
    private let state: SettingsRenderState
    private let cursorCLI = CursorLoginTests.FakeCLI()
    private let proxyWatch = CursorLoginTests.ProxyWatchStub()
    let appState: AppState
    let model: SettingsModel
    let navigation: SettingsNavigation
    let updater = UpdaterViewModel()

    init(style: InterfaceStyle, state: SettingsRenderState) {
        self.state = state
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(state.selected.map(\.rawValue), forKey: QuotaSelectionPreferences.selectedIDsKey)
        defaults.set(Self.order.map(\.rawValue), forKey: QuotaSelectionPreferences.orderKey)
        defaults.set(state.page.rawValue, forKey: SettingsNavigation.lastPageKey)

        let keys = MemoryKeys()
        if state.zCodeKey { keys.values[.bigModel] = "fixture-key" }

        let record: Data? = switch state.cursor {
        case .signedIn: CursorLoginTests.credential(email: "name@example.com")
        case .expired: CursorLoginRecord.ended(email: "name@example.com", at: Date()).data
        case .signedOut, .waiting, .failed: nil
        }
        let login = CursorLogin(
            store: CursorLoginTests.MemoryStore(record), cli: cursorCLI,
            openURL: { _ in }, watchProxy: proxyWatch.watch
        )
        login.load()

        // Classic without the style row is today's release build (choice not
        // offered); a forced style offers the row and switches in memory.
        let rollout: InterfaceStylePreference.Rollout =
            style == .classic && !state.styleRow ? .unreleased : .forced(style)
        let preference = InterfaceStylePreference(rollout: rollout)

        let detected = Set(Self.order).subtracting([.opencodeGo])
        appState = AppState(
            loadConfig: { nil },
            usageFetcher: { _, _, _ in throw CancellationError() },
            quotaDefaults: defaults,
            zCodeAPIKeyStore: keys,
            quotaProductDiscoverer: {
                QuotaProductRegistry.catalog.map { provider, availability in
                    QuotaProduct(provider: provider, availability: availability, isDetected: detected.contains(provider))
                }
            },
            cursorLogin: login,
            interfaceStyle: preference
        )
        appState.initializeQuotaProducts()
        appState.buckets = AppState.sampleUsageBuckets()
        navigation = SettingsNavigation(defaults: defaults)
        navigation.expandedProviders = state.expanded
        model = SettingsModel(appState: appState)
        model.apiKeyDisplay = "未配置"
        if state.warnings { appState.rateLimits = Self.warnings }
        if state.showTokens { appState.showTokensInMenuBar = true }
        state.apply?(model, appState)
    }

    /// Async parts of a state: the CLI support check and a Cursor sign-in.
    func prepare() async {
        let login = appState.cursorLogin
        await login.checkCLISupport()
        switch state.cursor {
        case .waiting:
            cursorCLI.signInGate = { try? await Task.sleep(nanoseconds: 60_000_000_000) }
            login.signIn()
            for _ in 0..<100 where login.phase != .waiting { await Task.yield() }
        case .failed:
            cursorCLI.signInAnswer = .failed(.timedOut)
            login.signIn()
            for _ in 0..<200 where login.errorText == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        case .signedOut, .signedIn, .expired:
            break
        }
    }

    var window: some View {
        SettingsWindowContent(menu: SettingsMenuState(opensOnLayout: state.menuOpen ? "egressMode" : nil))
            .environment(appState)
            .environment(navigation)
            .environment(model)
            .environmentObject(updater)
            .environment(\.settingsStaticPreview, true)
    }

    func cleanUp() {
        appState.cursorLogin.cancelSignIn()
        if state.showTokens {
            // `showTokensInMenuBar` writes the test runner's own defaults.
            UserDefaults.standard.removeObject(forKey: "showTokensInMenuBar")
        }
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private static let warnings: [ProviderRateLimit] = [
        ProviderRateLimit(provider: .codex, status: .unauthorized, fetchedAt: Date()),
        ProviderRateLimit(provider: .cursor, status: .noData, fetchedAt: Date(), liveFailure: .signInExpired),
        ProviderRateLimit(provider: .grok, status: .ok, fetchedAt: Date(), liveFailure: .egressRegionUnsupported("CN")),
        ProviderRateLimit(provider: .antigravity, status: .retryableError, fetchedAt: Date(), liveFailure: .cliTimedOut),
        ProviderRateLimit(provider: .kimiCode, status: .error("fixture"), fetchedAt: Date()),
    ]
}
