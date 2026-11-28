import AppKit
import SwiftUI
import Testing
@testable import VibeUsage

/// Off-screen renders of the interface-style rollout's two banners (#113),
/// driven by the real preference: the fixture's own domain holds the old
/// app's keys and uses the released rollout, so the first judgment keeps it
/// on classic with the classic banner; 「切换新版」 is the real
/// `AppState.acceptClassicStyleReminder()`. Opt-in:
///
///     VIBE_USAGE_RENDER_STYLE_REMINDERS=<dir> swift test --filter InterfaceStyleReminderRenderTests
///
/// The classic panel (520 × 620) is drawn under the system's light and dark
/// appearance (it is dark either way; native controls follow the system);
/// the new panel is dark only. Fixtures only (`PanelFixture`,
/// `RecentUsageFixtures`): isolated preferences, a fixture config, no
/// network, no Keychain.
struct InterfaceStyleReminderRenderTests {
    nonisolated static let outputDirectory = ProcessInfo.processInfo.environment["VIBE_USAGE_RENDER_STYLE_REMINDERS"]
    nonisolated static let readmeDirectory = ProcessInfo.processInfo.environment["VIBE_USAGE_RENDER_README"]

    private static let fourSubscriptions: [ProviderRateLimit.Provider] = [.claudeCode, .codex, .cursor, .grok]

    @Test(.enabled(if: outputDirectory != nil))
    @MainActor func renderBanners() async throws {
        let bundle = try #require(PanelTestResources.bundle)
        AppFonts.register(from: bundle)
        let directory = URL(fileURLWithPath: Self.outputDirectory!, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1. The classic panel of an upgraded user, linked and not linked.
        for (linked, dark, name) in [(true, false, "1-经典横幅-浅色"), (true, true, "1-经典横幅-深色"),
                                     (false, true, "5-经典横幅-未链接账号-深色")] {
            let fixture = PanelFixture(PanelScene(
                id: "classic-reminder", title: "经典：老用户横幅", linked: linked,
                recent: linked ? RecentUsageScene(range: .oneDay) : nil, styleRollout: .released
            ))
            defer { fixture.tearDown() }
            #expect(fixture.state.interfaceStyle.current == .classic)
            #expect(fixture.state.interfaceStyle.showsClassicReminder)
            fixture.state.applyDefaultTimeRangeForInterfaceStyle()
            try await fixture.prepare()
            let png = try await Self.renderClassic(fixture: fixture, dark: dark)
            try Self.write(png, "\(name).png", to: directory)
        }

        // 2. The new panel after 「切换新版」, against the same panel without
        // the banner: collapsed, expanded, one subscription (no 概览 row).
        let scenes: [(name: String, subscriptions: [ProviderRateLimit.Provider], expanded: Bool)] = [
            ("收起", Self.fourSubscriptions, false),
            ("展开", Self.fourSubscriptions, true),
            ("单个订阅", [.claudeCode], false),
        ]
        for (index, scene) in scenes.enumerated() {
            var heights: [Bool: CGFloat] = [:]
            for banner in [true, false] {
                let fixture = PanelFixture(PanelScene(
                    id: "switch-back", title: "新版：切回横幅", subscriptions: scene.subscriptions,
                    expanded: scene.expanded, recent: RecentUsageScene(),
                    styleRollout: banner ? .released : .externalTest
                ))
                defer { fixture.tearDown() }
                if banner { fixture.state.acceptClassicStyleReminder() }
                #expect(fixture.state.interfaceStyle.current == .modern)
                #expect(fixture.state.interfaceStyle.showsSwitchBackReminder == banner)
                try await fixture.prepare()
                let (png, height) = try await Self.renderModern(fixture: fixture)
                heights[banner] = height
                let name = banner ? "\(index + 2)-新版切回横幅-\(scene.name)" : "对照-新版无横幅-\(scene.name)"
                try Self.write(png, "\(name).png", to: directory)
            }
            let with = try #require(heights[true]), without = try #require(heights[false])
            #expect(with - without == ModernSwitchBackBanner.height + ModernTheme.cardSpacing)
            print("[style-reminders] \(scene.name): 无横幅 \(without) → 有横幅 \(with)")
        }
    }

    /// The README's two screenshots (`docs/demo-1.png`, `docs/demo-2.png`):
    /// the new panel on 概览 and inside one subscription, on a transparent
    /// background so they sit on GitHub's light and dark pages. States that
    /// list terminal names are left out (the fixtures' names are made up but
    /// personal-looking).
    @Test(.enabled(if: readmeDirectory != nil))
    @MainActor func renderReadmeScreenshots() async throws {
        let bundle = try #require(PanelTestResources.bundle)
        AppFonts.register(from: bundle)
        let directory = URL(fileURLWithPath: Self.readmeDirectory!, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, selected) in [("demo-1", nil), ("demo-2", ProviderRateLimit.Provider.claudeCode)] {
            let fixture = PanelFixture(PanelScene(
                id: "readme", title: "README", selected: selected, recent: RecentUsageScene()
            ))
            defer { fixture.tearDown() }
            try await fixture.prepare()
            let (png, _) = try await Self.renderModern(fixture: fixture, transparent: true)
            try Self.write(png, "\(name).png", to: directory)
        }
    }

    private static func write(_ png: Data, _ name: String, to directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try png.write(to: url)
        print("[style-reminders] \(url.path)")
    }

    private static let margin: CGFloat = 24

    private static func desktop(dark: Bool) -> Color {
        dark ? Color(white: 0.17) : Color(settingsHex: 0xE9E7E2)
    }

    /// The classic panel with the window's 12 pt corners and shadow, on a
    /// desktop tone matching the appearance, in a window of that appearance.
    @MainActor
    private static func renderClassic(fixture: PanelFixture, dark: Bool) async throws -> Data {
        let size = CGSize(width: 520, height: 620)
        let framed = PanelRootView(layout: ModernPanelLayout())
            .environment(fixture.state)
            .environmentObject(fixture.updater)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(dark ? 0.5 : 0.28), radius: 16, y: 12)
            .padding(margin)
            .background(desktop(dark: dark))
        let host = BannerOffscreenHost(
            framed, size: CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin),
            appearance: dark ? .darkAqua : .aqua
        )
        for _ in 0..<3 { try await host.settle() }
        return try host.png(scale: 2)
    }

    /// The new panel at the height it asks for (what `MenuBarController`
    /// sizes the window to), with its 16 pt corners and shadow, dark.
    @MainActor
    private static func renderModern(fixture: PanelFixture, transparent: Bool = false) async throws -> (Data, CGFloat) {
        var preview = RecentUsagePreview()
        preview.now = RecentUsageFixtures.now
        let reported = ReportedHeight()
        let measuring = ModernPanelView { reported.value = $0 }
            .environment(fixture.state)
            .environment(\.recentUsagePreview, preview)
            .environmentObject(fixture.updater)
        let probe = BannerOffscreenHost(measuring, size: CGSize(width: 520, height: 2_000), appearance: .darkAqua)
        for _ in 0..<40 where reported.value == nil { try await probe.settle() }
        try await probe.settle()
        let height = try #require(reported.value)

        // A transparent shot needs room for the whole shadow.
        let inset = transparent ? 32 : margin
        let framed = ModernPanelView()
            .environment(fixture.state)
            .environment(\.recentUsagePreview, preview)
            .environmentObject(fixture.updater)
            .frame(width: 520, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(transparent ? 0.35 : 0.5), radius: 16, y: 12)
            .padding(inset)
            .background(transparent ? Color.clear : desktop(dark: true))
        let host = BannerOffscreenHost(
            framed, size: CGSize(width: 520 + 2 * inset, height: height + 2 * inset), appearance: .darkAqua
        )
        for _ in 0..<3 { try await host.settle() }
        return (try host.png(scale: 2), height)
    }
}

@MainActor
private final class ReportedHeight {
    var value: CGFloat?
}

/// A borderless window never ordered on screen; `cacheDisplay` draws the
/// hosting view (scroll views included) into a bitmap.
@MainActor
private final class BannerOffscreenHost<Content: View> {
    private let window: NSWindow
    private let host: NSHostingView<Content>

    init(_ content: Content, size: CGSize, appearance: NSAppearance.Name) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: content)
        host.sizingOptions = []
        window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
    }

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
