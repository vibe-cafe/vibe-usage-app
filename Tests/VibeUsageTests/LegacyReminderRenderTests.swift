import AppKit
import SwiftUI
import Testing
@testable import VibeUsage

/// Prototype renders (#113): the classic panel at its real 520 × 620 with the
/// upgraded user's one-time banner (system light and dark appearance; the
/// panel is dark either way), and the dark-only new panel with the
/// switch-back banner shown after 「切换新版」. Opt-in:
///
///     VIBE_USAGE_RENDER_LEGACY_REMINDER=<dir> swift test --filter LegacyReminderRenderTests
///
/// Fixtures only (`PanelFixture`, `RecentUsageFixtures`): isolated
/// preferences, a fixture config, no network, no Keychain.
struct LegacyReminderRenderTests {
    nonisolated static let outputDirectory = ProcessInfo.processInfo.environment["VIBE_USAGE_RENDER_LEGACY_REMINDER"]

    @Test(.enabled(if: outputDirectory != nil))
    @MainActor func renderReminderLooks() async throws {
        let bundle = try #require(PanelTestResources.bundle)
        AppFonts.register(from: bundle)
        let directory = URL(fileURLWithPath: Self.outputDirectory!, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1. The classic panel's banner, new copy.
        for dark in [false, true] {
            let fixture = PanelFixture(PanelScene(
                id: "legacy-reminder", title: "经典：老用户提醒",
                recent: RecentUsageScene(range: .oneDay)
            ))
            defer { fixture.tearDown() }
            fixture.state.interfaceStyle.select(.classic)
            try await fixture.prepare()
            let png = try await Self.renderClassic(fixture: fixture, look: .banner, dark: dark)
            try Self.write(png, "1-经典横幅-新文案-\(dark ? "深色" : "浅色").png", to: directory)
        }

        // 2. The new panel after 「切换新版」: the switch-back banner under the
        // 概览 row (collapsed, expanded) or under the header (one
        // subscription), each against the same panel without it. The new
        // panel is dark only, so the system's dark appearance only.
        let scenes: [(name: String, subscriptions: [ProviderRateLimit.Provider], expanded: Bool)] = [
            ("收起", [.claudeCode, .codex, .cursor, .grok], false),
            ("展开", [.claudeCode, .codex, .cursor, .grok], true),
            ("单个订阅", [.claudeCode], false),
        ]
        for (index, scene) in scenes.enumerated() {
            var heights: [Bool: CGFloat] = [:]
            for notice in [true, false] {
                let fixture = PanelFixture(PanelScene(
                    id: "switch-back", title: "新版：切回横幅", subscriptions: scene.subscriptions,
                    expanded: scene.expanded, recent: RecentUsageScene()
                ))
                defer { fixture.tearDown() }
                try await fixture.prepare()
                let (png, height) = try await Self.renderModern(fixture: fixture, notice: notice, dark: true)
                heights[notice] = height
                let name = notice ? "\(index + 2)-新版切回横幅-\(scene.name).png" : "对照-新版无横幅-\(scene.name).png"
                try Self.write(png, name, to: directory)
            }
            print("[legacy-reminder] \(scene.name): 无横幅 \(heights[false]!) → 有横幅 \(heights[true]!)")
        }
    }

    private static func write(_ png: Data, _ name: String, to directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try png.write(to: url)
        print("[legacy-reminder] \(url.path)")
    }

    private static let margin: CGFloat = 24

    private static func desktop(dark: Bool) -> Color {
        dark ? Color(white: 0.17) : Color(settingsHex: 0xE9E7E2)
    }

    /// The classic panel with the window's 12 pt corners and shadow, on a
    /// desktop tone matching the appearance (light: the design board; dark: a
    /// dark desktop), drawn in a window of that appearance.
    @MainActor
    private static func renderClassic(fixture: PanelFixture, look: LegacyStyleReminderLook?, dark: Bool) async throws -> Data {
        let size = CGSize(width: 520, height: 620)
        let framed = PanelRootView(layout: ModernPanelLayout())
            .environment(fixture.state)
            .environmentObject(fixture.updater)
            .environment(\.legacyStyleReminderLook, look)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(dark ? 0.5 : 0.28), radius: 16, y: 12)
            .padding(margin)
            .background(desktop(dark: dark))
        let host = ReminderOffscreenHost(
            framed, size: CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin),
            appearance: dark ? .darkAqua : .aqua
        )
        for _ in 0..<3 { try await host.settle() }
        return try host.png(scale: 2)
    }

    /// The new panel at the height it asks for (what `MenuBarController`
    /// sizes the window to), with its 16 pt corners and shadow.
    @MainActor
    private static func renderModern(fixture: PanelFixture, notice: Bool, dark: Bool) async throws -> (Data, CGFloat) {
        var preview = RecentUsagePreview()
        preview.now = RecentUsageFixtures.now
        let reported = ReportedHeight()
        let measuring = ModernPanelView { reported.value = $0 }
            .environment(fixture.state)
            .environment(\.recentUsagePreview, preview)
            .environment(\.modernSwitchBackNotice, notice)
            .environmentObject(fixture.updater)
        let probe = ReminderOffscreenHost(measuring, size: CGSize(width: 520, height: 2_000), appearance: .darkAqua)
        for _ in 0..<40 where reported.value == nil { try await probe.settle() }
        try await probe.settle()
        let height = try #require(reported.value)

        let framed = ModernPanelView()
            .environment(fixture.state)
            .environment(\.recentUsagePreview, preview)
            .environment(\.modernSwitchBackNotice, notice)
            .environmentObject(fixture.updater)
            .frame(width: 520, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(dark ? 0.5 : 0.28), radius: 16, y: 12)
            .padding(margin)
            .background(desktop(dark: dark))
        let host = ReminderOffscreenHost(
            framed, size: CGSize(width: 520 + 2 * margin, height: height + 2 * margin),
            appearance: dark ? .darkAqua : .aqua
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
private final class ReminderOffscreenHost<Content: View> {
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
