import SwiftUI

/// Manages a standalone NSWindow for settings.
/// Settings is kept as an explicit NSWindow so it can coexist cleanly with the
/// custom menu-bar panel and Sparkle's normal AppKit dialogs.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(appState: AppState, updaterViewModel: UpdaterViewModel) {
        // ActivationCoordinator remains the single policy touch point; while
        // Settings is visible it keeps the app `.regular` even if the user
        // has hidden the Dock icon.
        ActivationCoordinator.shared.settingsDidOpen()
        NSApp.activate(ignoringOtherApps: true)

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView()
            .environment(appState)
            .environmentObject(updaterViewModel)

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(AppConfig.displayName) Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        ActivationCoordinator.shared.settingsDidClose()
    }
}
