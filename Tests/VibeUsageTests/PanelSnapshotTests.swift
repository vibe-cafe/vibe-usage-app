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
    /// 近期消耗's data, period, filters, units and forced hover (linked scenes).
    var usage = RecentUsageScene()

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
        PanelScene(id: "136i", title: "展开以后：收起详情", expanded: true),
        PanelScene(id: "136j", title: "没登录：近期消耗换成登录，底栏只剩关闭", linked: false, lastSyncMinutesAgo: nil),
        PanelScene(id: "136k", title: "登录：等浏览器里确认", linked: false, lastSyncMinutesAgo: nil, signIn: .waiting),
        PanelScene(id: "136k-asking", title: "登录：验证码还没拿到", linked: false, lastSyncMinutesAgo: nil, signIn: .asking),
        PanelScene(id: "136l", title: "登录没成功：原因和重新登录", linked: false, lastSyncMinutesAgo: nil, signIn: .failed),
        PanelScene(id: "overflow", title: "展开后超过屏幕：顶栏底栏固定、中间滚动", expanded: true, maxHeight: 640),
    ] + recentUsageScenes

    /// 近期消耗 (134a–134s) and a few states the design did not draw.
    static let recentUsageScenes: [PanelScene] = {
        func scene(_ id: String, _ title: String, _ usage: RecentUsageScene, selected: ProviderRateLimit.Provider? = nil) -> PanelScene {
            PanelScene(id: id, title: title, selected: selected, usage: usage)
        }
        let codex = FilterState(sources: ["codex"])
        return [
            scene("134a", "平时：今天", .init()),
            scene("134b", "鼠标停在曲线上", .init(preview: .init(hoveredSlot: 2))),
            scene("134c", "24H：鼠标停在昨晚", .init(range: .oneDay, preview: .init(hoveredSlot: 6))),
            scene("134d", "7D：一天一个点", .init(range: .sevenDays)),
            scene("134e", "筛选菜单：四行", .init(preview: .init(menu: .some(nil)))),
            scene("134f", "工具那一行，选了 Codex", .init(range: .sevenDays, filters: codex, preview: .init(menu: .tool))),
            scene("134g", "选好以后：7D、Codex", .init(range: .sevenDays, filters: codex)),
            scene("134h", "自定义日期", .init(range: .custom, preview: .init(menu: .time))),
            scene("134i", "自定义日期选好以后", .init(range: .custom)),
            scene("134j", "工具多选：Codex +1", .init(filters: FilterState(sources: ["codex", "cursor"]),
                                                  preview: .init(menu: .tool))),
            scene("134k", "模型按家族分组", .init(filters: FilterState(models: ["Opus 5.5", "Sonnet 5.5"]),
                                                  preview: .init(menu: .model, expandedFamilies: ["claude"]))),
            scene("134l", "Token 当大数字，悬停看细分", .init(hero: .token, preview: .init(hoveredSlot: 5))),
            scene("134m", "活跃当大数字", .init(hero: .activeTime)),
            scene("134n", "费用换成人民币", .init(cny: true)),
            scene("134o", "Token 换成万、亿", .init(hero: .token, chineseTokens: true)),
            scene("134p", "鼠标停在大数字上", .init(preview: .init(heroHovered: true))),
            scene("134q", "第一次打开，还没读出来", .init(loading: .initial)),
            scene("134r", "换了周期，旧的变淡", .init(loading: .switching(.sevenDays))),
            scene("134s", "这段时间没有用量", .init(empty: true)),
            scene("134-active-hover", "活跃当大数字，悬停看 AI 工时", .init(hero: .activeTime, preview: .init(hoveredSlot: 1))),
            scene("134-active-row", "悬停小数字「活跃」", .init(preview: .init(activityHovered: true))),
            scene("134-active-hero-hover", "活跃当大数字，悬停大数字", .init(hero: .activeTime, preview: .init(heroHovered: true))),
            scene("134-90d", "90D：按周", .init(range: .ninetyDays)),
            scene("134-30d", "30D", .init(range: .thirtyDays, hero: .token)),
            scene("134-locked", "点进 Codex：工具一行锁定", .init(preview: .init(menu: .some(nil))), selected: .codex),
            scene("134-chips", "条件很多时标题那一行", .init(
                range: .custom,
                filters: FilterState(sources: ["codex", "cursor"], models: ["Opus 5.5"], hostnames: ["Hogans-MacBook-Pro"])
            )),
        ]
    }()
}

/// What 近期消耗 shows in a scene.
struct RecentUsageScene {
    var range: TimeRange = .today
    var hero: ChartMode = .cost
    var cny = false
    var chineseTokens = false
    var filters = FilterState()
    /// No usage in the period (134s).
    var empty = false
    var loading: Loading = .none
    var preview = RecentUsagePreview()

    enum Loading {
        case none
        /// The first read has not answered (134q).
        case initial
        /// Loaded, then switched to another period that has not answered (134r).
        case switching(TimeRange)
    }
}

/// An AppState (and updater) holding a scene's data.
@MainActor
final class PanelFixture {
    let state: AppState
    let updater = UpdaterViewModel()
    let scene: PanelScene
    private let reads: FixtureReads
    private var pending: [Task<Void, Never>] = []
    /// Runs once the rendered view has laid out with the loaded data: the
    /// switch to a period that is still loading (134r) must find the view
    /// already showing the previous one.
    private(set) var afterFirstLayout: (@MainActor () async throws -> Void)?
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
        let reads = FixtureReads(empty: scene.usage.empty)
        self.reads = reads
        state = AppState(
            initialConfig: config,
            loadConfig: { config },
            usageFetcher: { _, _, range in
                try await reads.waitIfHanging()
                return RecentUsageFixtures.response(for: range, empty: reads.empty)
            },
            activityFetcher: { _, _, range, _ in
                try await reads.waitIfHanging()
                return RecentUsageFixtures.activity(for: range, empty: reads.empty)
            },
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

    /// Loads 近期消耗's data (or leaves a read hanging), or walks the
    /// sign-in to the scene's step against the fixture server.
    func prepare() async throws {
        if scene.linked {
            try await prepareUsage()
            return
        }
        guard scene.signIn != .idle else { return }
        state.deviceLink.start()
        for _ in 0..<200 {
            switch (scene.signIn, state.deviceLink.phase) {
            case (.asking, .requestingCode), (.waiting, .awaitingApproval), (.failed, .failed): return
            default: try await Task.sleep(for: .milliseconds(5))
            }
        }
        Issue.record("sign-in did not reach \(scene.signIn)")
    }

    private func prepareUsage() async throws {
        let usage = scene.usage
        let custom = RecentUsageFixtures.customRange
        state.customRangeFrom = custom.from
        state.customRangeTo = custom.to
        state.filters = usage.filters
        state.modernPanel.hero = usage.hero
        if usage.cny {
            state.modernPanel.hero = .cost
            state.modernPanel.usage.toggleHeroUnit()
        }
        if usage.chineseTokens {
            state.modernPanel.hero = .token
            state.modernPanel.usage.toggleHeroUnit()
        }
        state.modernPanel.hero = usage.hero
        switch usage.loading {
        case .none:
            state.timeRange = usage.range
            await state.fetchUsageData()
            try await waitFor { self.state.activity != nil }
        case .initial:
            state.timeRange = usage.range
            reads.hangs = true
            pending.append(Task { await self.state.fetchUsageData() })
            try await waitFor { self.state.isLoadingData }
        case .switching(let next):
            state.timeRange = usage.range
            await state.fetchUsageData()
            try await waitFor { self.state.activity != nil }
            afterFirstLayout = { [self] in
                reads.hangs = true
                state.timeRange = next
                pending.append(Task { await self.state.fetchUsageData() })
                try await waitFor { self.state.isLoadingData }
            }
        }
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    func tearDown() {
        pending.forEach { $0.cancel() }
        reads.release()
        state.deviceLink.cancel()
        defaults.removePersistentDomain(forName: suite)
    }
}

/// The fixture server's reads: answered at once, or left hanging until the
/// scene is torn down (a read still loading).
@MainActor
private final class FixtureReads: Sendable {
    let empty: Bool
    var hangs = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(empty: Bool) { self.empty = empty }

    func waitIfHanging() async throws {
        guard hangs else { return }
        await withCheckedContinuation { waiters.append($0) }
        throw CancellationError()
    }

    func release() {
        hangs = false
        waiters.forEach { $0.resume() }
        waiters = []
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
    static func render(fixture: PanelFixture, maxHeight: CGFloat, scale: CGFloat = 2) async throws -> Data {
        var preview = fixture.scene.usage.preview
        preview.now = RecentUsageFixtures.now
        let reported = HeightBox()
        let measuring = ModernPanelView(maxHeight: maxHeight) { reported.value = $0 }
            .environment(fixture.state)
            .environment(\.recentUsagePreview, preview)
            .environmentObject(fixture.updater)
        let probe = OffscreenHost(measuring, size: CGSize(width: ModernTheme.panelWidth, height: 2_000))
        for _ in 0..<40 where reported.value == nil {
            try await probe.settle()
        }
        try await probe.settle()
        let height = try #require(reported.value)

        let framed = ModernPanelView(maxHeight: maxHeight)
            .environment(fixture.state)
            .environment(\.recentUsagePreview, preview)
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
        if let action = fixture.afterFirstLayout {
            try await action()
            try await host.settle()
            try await host.settle()
        }
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
