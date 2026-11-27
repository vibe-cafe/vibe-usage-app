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
            try await fixture.prepare()
            let png = try await PanelSnapshot.render(fixture: fixture, maxHeight: scene.maxHeight,
                                                     scrolledToEnd: scene.scrolledToEnd)
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

    /// Crops of the details cards (135d, the faded figures of 134r): states
    /// held inside the view, which a whole-panel scene cannot set.
    @Test(.enabled(if: PanelSnapshot.isEnabled))
    @MainActor func renderDetailCrops() async throws {
        let bundle = try #require(PanelTestResources.bundle)
        AppFonts.register(from: bundle)
        let directory = PanelSnapshot.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        struct Crop {
            let id: String
            let usage: PanelUsage
            var open: UsageRanking.Dimension?
            var faded = false
        }
        let crops = [
            Crop(id: "135d", usage: .today, open: .model),
            Crop(id: "135d-up", usage: .many, open: .tool),
            Crop(id: "135d-scroll", usage: .many, open: .model),
            Crop(id: "135-faded", usage: .today, faded: true),
        ]
        let wanted = ProcessInfo.processInfo.environment["VIBE_USAGE_RENDER_SCENES"]
            .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        for crop in crops where wanted?.contains(crop.id) ?? true {
            let fixture = PanelFixture(PanelScene(id: crop.id, title: crop.id, usage: crop.usage))
            defer { fixture.tearDown() }
            try await fixture.prepare()
            // A new period whose response has not come back yet.
            var fade: (@MainActor (AppState) -> Void)?
            if crop.faded {
                fade = { state in
                    state.timeRange = .sevenDays
                    state.isLoadingData = true
                }
            }
            let png = try await PanelSnapshot.renderDetails(fixture: fixture, openRemainder: crop.open, change: fade)
            let url = directory.appendingPathComponent("\(crop.id).png")
            try png.write(to: url)
            print("[panel-snapshot] \(crop.id) → \(url.path)")
        }
    }

    /// The classic panel without a linked account, at its 520 × 620 size,
    /// in the three sign-in steps it shares with the new panel.
    @Test(.enabled(if: PanelSnapshot.isEnabled))
    @MainActor func renderClassicSignIn() async throws {
        let bundle = try #require(PanelTestResources.bundle)
        AppFonts.register(from: bundle)
        let directory = PanelSnapshot.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for step in [PanelScene.SignIn.idle, .waiting, .failed] {
            let fixture = PanelFixture(PanelScene(id: "classic-signin", title: "经典：没登录", linked: false, signIn: step))
            defer { fixture.tearDown() }
            fixture.state.interfaceStyle.select(.classic)
            try await fixture.prepare()
            let host = OffscreenHost(
                PanelRootView(layout: ModernPanelLayout())
                    .environment(fixture.state)
                    .environmentObject(fixture.updater),
                size: CGSize(width: ModernTheme.panelWidth, height: 620)
            )
            try await host.settle()
            try await host.settle()
            try host.png(scale: 2).write(to: directory.appendingPathComponent("classic-signin-\(step).png"))
        }
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
    /// The device sign-in's step (unlinked scenes).
    var signIn: SignIn = .idle
    /// Usage the fixture server answers with; nil = never asked (no figures).
    var usage: PanelUsage?
    var timeRange: TimeRange = .today
    var filters: FilterState = .init()
    /// Token / 费用 of the details cards; unset ones are Token.
    var metrics: [UsageRanking.Dimension: MetricMode] = [:]
    /// The first usage read is still on its way.
    var loading = false
    /// Drawn with the scrolling middle at its end (`maxHeight` scenes).
    var scrolledToEnd = false

    enum SignIn: String {
        /// 「登录并链接数据」.
        case idle
        /// Asked the server for a code, no answer yet.
        case asking
        /// Code shown, waiting for the browser.
        case waiting
        /// The code expired.
        case failed
    }

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
        PanelScene(id: "136i", title: "展开以后：收起详情", expanded: true, usage: .today),
        PanelScene(id: "136j", title: "没登录：近期消耗换成登录，底栏只剩关闭", linked: false, lastSyncMinutesAgo: nil),
        PanelScene(id: "136k", title: "登录：等浏览器里确认", linked: false, lastSyncMinutesAgo: nil, signIn: .waiting),
        PanelScene(id: "136k-asking", title: "登录：验证码还没拿到", linked: false, lastSyncMinutesAgo: nil, signIn: .asking),
        PanelScene(id: "136l", title: "登录没成功：原因和重新登录", linked: false, lastSyncMinutesAgo: nil, signIn: .failed),
        PanelScene(id: "overflow", title: "展开后超过屏幕：顶栏底栏固定、中间滚动", expanded: true, maxHeight: 640,
                   usage: .today),
        PanelScene(id: "overflow-end", title: "展开后超过屏幕：中间滚到底，底栏仍在", expanded: true, maxHeight: 640,
                   usage: .today, scrolledToEnd: true),
        // 135: 展开详情.
        PanelScene(id: "135a", title: "展开详情：今天，四张卡，都按 Token", expanded: true, usage: .today),
        PanelScene(id: "135b", title: "周期 7D、工具 Codex，再展开：只算 Codex 这 7 天", expanded: true,
                   usage: .week, timeRange: .sevenDays, filters: FilterState(sources: ["codex"])),
        PanelScene(id: "135c", title: "模型分布换成费用：按钱排名次", expanded: true, usage: .today,
                   metrics: [.model: .cost]),
        PanelScene(id: "135c-all", title: "三个分布都按费用", expanded: true, usage: .today,
                   metrics: [.model: .cost, .terminal: .cost, .tool: .cost]),
        PanelScene(id: "135e", title: "名字太长：中间省略", expanded: true, usage: .longNames),
        PanelScene(id: "135-selected", title: "点进 Claude：四张卡只算 Claude Code", selected: .claudeCode,
                   expanded: true, usage: .today),
        PanelScene(id: "135-single", title: "只有一个订阅：四张卡仍是全部用量", subscriptions: [.claudeCode],
                   expanded: true, usage: .today),
        PanelScene(id: "135-filter", title: "终端筛选 Mac-Studio", expanded: true, usage: .today,
                   filters: FilterState(hostnames: ["Mac-Studio"])),
        PanelScene(id: "135-filter-empty", title: "筛选后没有用量", expanded: true, usage: .today,
                   filters: FilterState(hostnames: ["Mac-mini"])),
        PanelScene(id: "135-empty", title: "这段时间没有用量", expanded: true, usage: PanelUsage.none),
        PanelScene(id: "135-loading", title: "第一次打开，用量还没读出来", expanded: true, loading: true),
        PanelScene(id: "135-many", title: "模型、工具很多：前三名加其余", expanded: true, usage: .many),
    ]
}

/// An AppState (and updater) holding a scene's data.
@MainActor
final class PanelFixture {
    let state: AppState
    let updater = UpdaterViewModel()
    private let scene: PanelScene
    private let defaults: UserDefaults
    private let suite: String

    init(_ scene: PanelScene, now: Date = Date()) {
        self.scene = scene
        suite = "PanelSnapshot.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(scene.subscriptions.map(\.rawValue), forKey: QuotaSelectionPreferences.selectedIDsKey)
        if let minutes = scene.lastSyncMinutesAgo {
            defaults.set(now.addingTimeInterval(-minutes * 60), forKey: AppState.lastSuccessfulSyncKey)
        }
        let config = scene.linked ? VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test") : nil
        let usage = scene.usage
        state = AppState(
            initialConfig: config,
            loadConfig: { config },
            usageFetcher: { _, _, range in
                guard let usage else { throw URLError(.notConnectedToInternet) }
                return usage.response(for: range, now: now)
            },
            activityFetcher: { _, _, _, _ in throw URLError(.notConnectedToInternet) },
            quotaDefaults: defaults,
            zCodeAPIKeyStore: FixtureZCodeKeys(),
            quotaProductDiscoverer: {
                QuotaProductRegistry.catalog.map { QuotaProduct(provider: $0.0, availability: $0.1, isDetected: true) }
            },
            // Its own preference domain with the external-test rollout: a
            // fresh domain starts on the new panel, in Debug and Release.
            interfaceStyle: InterfaceStylePreference(domain: suite, rollout: .externalTest),
            deviceLinkService: .fixture(scene.signIn)
        )
        state.initializeQuotaProducts()
        state.syncStatus = scene.syncStatus
        state.modernPanel.selectedSubscription = scene.selected
        state.modernPanel.detailsExpanded = scene.expanded
        state.timeRange = scene.timeRange
        state.filters = scene.filters
        for (dimension, metric) in scene.metrics { state.modernPanel[metricFor: dimension] = metric }
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

    /// Loads the scene's usage from the fixture server, or walks the sign-in
    /// to the scene's step against it.
    func prepare() async throws {
        if scene.linked, scene.usage != nil { await state.fetchUsageData() }
        if scene.loading { state.isLoadingData = true }
        guard !scene.linked, scene.signIn != .idle else { return }
        state.deviceLink.start()
        for _ in 0..<200 {
            switch (scene.signIn, state.deviceLink.phase) {
            case (.asking, .requestingCode), (.waiting, .awaitingApproval), (.failed, .failed): return
            default: try await Task.sleep(for: .milliseconds(5))
            }
        }
        Issue.record("sign-in did not reach \(scene.signIn)")
    }

    func tearDown() {
        state.deviceLink.cancel()
        defaults.removePersistentDomain(forName: suite)
    }
}

private extension DeviceLinkService {
    /// A server that never hands out a code (asking), or hands out the
    /// design's code and then never answers (waiting) or says it expired
    /// (failed). No browser is opened.
    static func fixture(_ step: PanelScene.SignIn) -> DeviceLinkService {
        DeviceLinkService(
            requestCode: { _, _, _ in
                if step == .asking { try await Task.sleep(for: .seconds(3_600)) }
                return DeviceCodeResponse(
                    deviceCode: "fixture", userCode: "WDJB-MJHT", verificationUri: "",
                    verificationUriComplete: "", expiresIn: 900, interval: 5
                )
            },
            poll: { _, _ in DevicePollResponse(apiKey: nil, apiUrl: nil, error: "expired_token") },
            sleep: { _ in
                if step == .waiting { try await Task.sleep(for: .seconds(3_600)) }
            },
            now: { Date() },
            openURL: { _ in },
            hostname: { nil }
        )
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
    static func render(fixture: PanelFixture, maxHeight: CGFloat, scrolledToEnd: Bool = false,
                       scale: CGFloat = 2) async throws -> Data {
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
        if scrolledToEnd {
            host.scrollToEnd()
            try await host.settle()
        }
        return try host.png(scale: scale)
    }

    /// The details cards alone (135c–135e crops): the grid at the panel's
    /// width on the panel's background. `change` runs after a first pass,
    /// for states that need a previous one (the faded figures of 134r).
    static func renderDetails(fixture: PanelFixture, openRemainder: UsageRanking.Dimension? = nil,
                              change: (@MainActor (AppState) -> Void)? = nil) async throws -> Data {
        let details = ModernDetailsSection(openRemainder: openRemainder)
            .padding(.horizontal, ModernTheme.cardInset)
            .padding(.vertical, 12)
            .frame(width: ModernTheme.panelWidth, alignment: .top)
            .background(ModernTheme.panel)
            .environment(\.colorScheme, .dark)
            .environment(fixture.state)
            .padding(margin)
            .background(board)
        let size = CGSize(width: ModernTheme.panelWidth + 2 * margin, height: 2 * 252 + 8 + 24 + 2 * margin)
        let host = OffscreenHost(details, size: size)
        try await host.settle()
        try await host.settle()
        if let change {
            change(fixture.state)
            try await host.settle()
            try await host.settle()
        }
        return try host.png(scale: 2)
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

    /// Scrolls the panel's middle (the one `NSScrollView`) to its end.
    func scrollToEnd() {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let scroll = find(host), let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let y = document.isFlipped ? document.bounds.height - clip.bounds.height : 0
        clip.scroll(to: CGPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
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
