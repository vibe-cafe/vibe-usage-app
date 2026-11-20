import SwiftUI

/// Manages a standalone NSWindow for settings.
/// Settings is kept as an explicit NSWindow so it can coexist cleanly with the
/// custom menu-bar panel and Sparkle's normal AppKit dialogs.
///
/// The window is 700 × 460 (it may be dragged taller, never wider), always
/// dark, with the content running under a transparent title bar so the
/// sidebar reaches the top edge. Only the close button is live, as Apple
/// recommends for settings windows.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    /// Outlives the window: the page it shows is remembered across openings.
    private let navigation = SettingsNavigation()

    /// - Parameter destination: `.lastPage` for the popover's 「设置」, or
    ///   `.quotas(focus:)` from the 订阅配额 strip (gear / grey product tab).
    func show(
        appState: AppState,
        updaterViewModel: UpdaterViewModel,
        destination: SettingsDestination = .lastPage
    ) {
        // ActivationCoordinator remains the single policy touch point; while
        // Settings is visible it keeps the app `.regular` even if the user
        // has hidden the Dock icon.
        ActivationCoordinator.shared.settingsDidOpen()
        NSApp.activate(ignoringOtherApps: true)

        if let window, window.isVisible {
            navigation.open(destination, zCodeKeyConfigured: appState.zCodeAPIKeyConfigured)
            window.makeKeyAndOrderFront(nil)
            return
        }

        navigation.resetTransientState()
        navigation.open(destination, zCodeKeyConfigured: appState.zCodeAPIKeyConfigured)

        let settingsView = SettingsView()
            .environment(appState)
            .environment(navigation)
            .environment(SettingsModel(appState: appState))
            .environmentObject(updaterViewModel)

        let hostingController = NSHostingController(rootView: settingsView)
        // The window, not SwiftUI's ideal size, decides the frame; the root
        // view's min/max frame keeps the width fixed.
        hostingController.sizingOptions = []

        let size = SettingsTheme.windowSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "\(AppConfig.displayName) Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = SettingsTheme.contentNSColor
        // With a full-size content view the frame is the window's real size
        // (the title bar is drawn over the content), so size by frame.
        window.minSize = size
        window.maxSize = NSSize(width: size.width, height: 10_000)
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        // Resizable only to grow taller; zoom would do nothing useful.
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        placeWindowButtons(in: window)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        ActivationCoordinator.shared.settingsDidClose()
    }

    // MARK: - Window buttons

    /// The design centers the window buttons 24 pt below the top edge,
    /// 22 pt in from the left (over the sidebar, whose items start at 52 pt);
    /// AppKit's default places them higher for a plain title bar. Only the
    /// position moves — the buttons stay the system's own. AppKit lays them
    /// out again on resize and key changes, so those re-apply it.
    static let windowButtonCenter = CGPoint(x: 22, y: 24)

    private func placeWindowButtons(in window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let first = buttons.first, let container = first.superview, buttons.count == 3 else { return }
        let spacing = buttons[1].frame.minX - buttons[0].frame.minX
        guard spacing > 0 else { return }
        let size = first.frame.size
        let fromTop = Self.windowButtonCenter.y - size.height / 2
        // Stay inside the title bar view: never move a button out of it.
        let y = container.isFlipped ? fromTop : container.bounds.height - fromTop - size.height
        guard y >= 0, y + size.height <= container.bounds.height else { return }
        let x = Self.windowButtonCenter.x - size.width / 2
        for (index, button) in buttons.enumerated() {
            button.setFrameOrigin(NSPoint(x: x + CGFloat(index) * spacing, y: y))
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow { placeWindowButtons(in: window) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { placeWindowButtons(in: window) }
    }

    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { placeWindowButtons(in: window) }
    }
}
