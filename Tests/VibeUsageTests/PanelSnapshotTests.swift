import AppKit
import Sparkle
import SwiftUI
import Testing
@testable import VibeUsage

/// Off-screen renderer for the new panel. Each scene is fixed data named after
/// the finalized design's id (`VibeUsage界面改版/深色/131-首屏.png` etc.); the
/// output is the real `ModernPanelView` with the bundled fonts and the app's
/// own icons, at 2×, on the design board's background so it can sit next to
/// the design screenshot. Visual tickets add their scenes to `scenes`.
///
/// Opt-in, skipped by default and in CI:
///
///     VIBE_USAGE_RENDER_PANEL=1 swift test --scratch-path .build --filter PanelSnapshotTests
///
/// `VIBE_USAGE_RENDER_SCENES=131a,136f` renders only those ids;
/// `VIBE_USAGE_SNAPSHOT_DIR` overrides the output directory
/// (default `.build/screenshots/panel/` in this checkout).
///
/// Nothing real is read: isolated preferences, a fixture config that is never
/// written, no quota coordinator, no sync.
struct PanelSnapshotTests {
    @Test(.enabled(if: PanelSnapshot.isEnabled))
    @MainActor func renderScenes() async throws {
        let bundle = try #require(PanelTestResources.bundle)
        #expect(AppFonts.register(from: bundle) == AppFonts.fileNames)
        let directory = PanelSnapshot.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let wanted = ProcessInfo.processInfo.environment["VIBE_USAGE_RENDER_SCENES"]
            .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        for scene in PanelScene.scenes where wanted?.contains(scene.id) ?? true {
            let fixture = PanelFixture(scene)
            defer { fixture.tearDown() }
            let png = try await PanelSnapshot.render(fixture: fixture, maxHeight: scene.maxHeight)
            let url = directory.appendingPathComponent("\(scene.id).png")
            try png.write(to: url)
            print("[panel-snapshot] \(scene.id) \(scene.title) → \(url.path)")
        }
    }

    /// One hosting view, as in the app: switching the style in memory swaps
    /// the panel without rebuilding the window.
    @Test(.enabled(if: PanelSnapshot.isEnabled))
    @MainActor func renderStyleSwitch() async throws {
        let bundle = try #require(PanelTestResources.bundle)
        AppFonts.register(from: bundle)
        let directory = PanelSnapshot.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = PanelFixture(PanelScene(id: "switch", title: "切换样式"))
        defer { fixture.tearDown() }
        let root = PanelRootView(layout: ModernPanelLayout())
            .environment(fixture.state)
            .environmentObject(fixture.updater)
        let host = OffscreenHost(root, size: CGSize(width: ModernTheme.panelWidth, height: 620))
        try await host.settle()
        let modern = try host.png(scale: 1)
        fixture.state.interfaceStyle.select(.classic)
        try await host.settle()
        let classic = try host.png(scale: 1)
        #expect(modern != classic)
        try modern.write(to: directory.appendingPathComponent("switch-modern.png"))
        try classic.write(to: directory.appendingPathComponent("switch-classic.png"))
    }
}

/// One rendered state of the panel.
struct PanelScene {
    let id: String
    let title: String
    var subscriptions: [ProviderRateLimit.Provider] = [.codex, .claudeCode, .cursor, .grok]
    var linked = true
    var syncStatus: SyncStatus = .idle
    /// Minutes since the last successful sync; nil = never synced.
    var lastSyncMinutesAgo: Double? = 26.5
    var selected: ProviderRateLimit.Provider?
    var expanded = false
    var hasUpdate = false
    var refreshing: Set<ProviderRateLimit.Provider> = []
    /// The screen's limit; finite values show the scrolling middle.
    var maxHeight: CGFloat = .infinity

    static let scenes: [PanelScene] = [
        PanelScene(id: "131a", title: "概览：4 个订阅"),
        PanelScene(id: "131b", title: "点进 Codex", selected: .codex),
        PanelScene(id: "132f", title: "还没有订阅", subscriptions: []),
        PanelScene(id: "132g", title: "只有一个订阅，没有概览那一排", subscriptions: [.claudeCode]),
        PanelScene(id: "132t", title: "刷新额度：读取中转圈", refreshing: [.claudeCode]),
        PanelScene(id: "136b", title: "顶栏：发现更新", hasUpdate: true),
        PanelScene(id: "136e", title: "底栏：同步中", syncStatus: .syncing),
        PanelScene(id: "136f", title: "底栏：同步出错", syncStatus: .error("同步失败: 连不上服务器")),
        PanelScene(id: "136f-long", title: "底栏：同步出错，原因很长时只截断原因", syncStatus: .error(
            "同步失败: 本地同步工具读取历史记录时崩溃（RangeError: Invalid string length）。请更新 @vibe-cafe/vibe-usage 后重试"
        )),
        PanelScene(id: "136g", title: "底栏：还没同步过", lastSyncMinutesAgo: nil),
        PanelScene(id: "136i", title: "展开以后：收起详情", expanded: true),
        PanelScene(id: "136j", title: "没登录：底栏只剩关闭", linked: false, lastSyncMinutesAgo: nil),
        PanelScene(id: "overflow", title: "展开后超过屏幕：顶栏底栏固定、中间滚动", expanded: true, maxHeight: 640),
    ]
}

/// An AppState (and updater) holding a scene's data.
@MainActor
final class PanelFixture {
    let state: AppState
    let updater = UpdaterViewModel()
    private let defaults: UserDefaults
    private let suite: String

    init(_ scene: PanelScene, now: Date = Date()) {
        suite = "PanelSnapshot.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(scene.subscriptions.map(\.rawValue), forKey: QuotaSelectionPreferences.selectedIDsKey)
        if let minutes = scene.lastSyncMinutesAgo {
            defaults.set(now.addingTimeInterval(-minutes * 60), forKey: AppState.lastSuccessfulSyncKey)
        }
        let config = scene.linked ? VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test") : nil
        state = AppState(
            initialConfig: config,
            loadConfig: { config },
            usageFetcher: { _, _, _ in throw URLError(.notConnectedToInternet) },
            quotaDefaults: defaults,
            zCodeAPIKeyStore: FixtureZCodeKeys(),
            quotaProductDiscoverer: {
                QuotaProductRegistry.catalog.map { QuotaProduct(provider: $0.0, availability: $0.1, isDetected: true) }
            },
            interfaceStyle: InterfaceStylePreference(rollout: .forced(.modern))
        )
        state.initializeQuotaProducts()
        state.syncStatus = scene.syncStatus
        state.modernPanel.selectedSubscription = scene.selected
        state.modernPanel.detailsExpanded = scene.expanded
        for provider in scene.refreshing {
            switch provider {
            case .codex: state.isCodexRateLimitRefreshing = true
            case .claudeCode: state.isClaudeRateLimitRefreshing = true
            case .opencodeGo: state.isOpenCodeGoRateLimitRefreshing = true
            default: state.cliQuotaRefreshingProviders.insert(provider)
            }
        }
        if scene.hasUpdate { updater.availableUpdate = SUAppcastItem.empty() }
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class FixtureZCodeKeys: ZCodeAPIKeyStoring {
    func load(for region: ZCodeQuotaRegion) throws -> String? { nil }
    func store(_ value: String?, for region: ZCodeQuotaRegion) throws {}
}

@MainActor
enum PanelSnapshot {
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["VIBE_USAGE_RENDER_PANEL"] == "1"
    }

    nonisolated static var outputDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["VIBE_USAGE_SNAPSHOT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/screenshots/panel", isDirectory: true)
    }

    /// Margin of design-board background around the panel.
    static let margin: CGFloat = 24
    /// The design board's background (`#e9e7e2`).
    static let board = Color(settingsHex: 0xE9E7E2)

    /// Lays the panel out once to learn the height it asks for (the same
    /// number `MenuBarController` would size the window to), then draws it at
    /// that height with the window's 16 pt corners and shadow.
    static func render(fixture: PanelFixture, maxHeight: CGFloat, scale: CGFloat = 2) async throws -> Data {
        let reported = HeightBox()
        let measuring = ModernPanelView(maxHeight: maxHeight) { reported.value = $0 }
            .environment(fixture.state)
            .environmentObject(fixture.updater)
        let probe = OffscreenHost(measuring, size: CGSize(width: ModernTheme.panelWidth, height: 2_000))
        for _ in 0..<40 where reported.value == nil {
            try await probe.settle()
        }
        try await probe.settle()
        let height = try #require(reported.value)

        let framed = ModernPanelView(maxHeight: maxHeight)
            .environment(fixture.state)
            .environmentObject(fixture.updater)
            .frame(width: ModernTheme.panelWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: ModernTheme.panelCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ModernTheme.panelCornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 16, y: 12)
            .padding(margin)
            .background(board)
        let size = CGSize(width: ModernTheme.panelWidth + 2 * margin, height: height + 2 * margin)
        let host = OffscreenHost(framed, size: size)
        try await host.settle()
        try await host.settle()
        return try host.png(scale: scale)
    }
}

/// Written by the view on the main actor.
@MainActor
private final class HeightBox {
    var value: CGFloat?
}

/// A borderless window that is never ordered on screen, hosting SwiftUI the
/// way the app does (an `NSHostingView` content view, no intrinsic sizing).
/// `cacheDisplay` draws it into a bitmap; AppKit-backed views such as the
/// panel's `ScrollView` draw too, which `ImageRenderer` cannot do.
@MainActor
private final class OffscreenHost<Content: View> {
    private let window: NSWindow
    private let host: NSHostingView<Content>

    init(_ content: Content, size: CGSize) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: content)
        host.sizingOptions = []
        window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
    }

    /// Lets SwiftUI finish a pass (state written from geometry callbacks,
    /// `onChange`) before the next read.
    func settle() async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
    }

    func png(scale: CGFloat) throws -> Data {
        let size = host.bounds.size
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
