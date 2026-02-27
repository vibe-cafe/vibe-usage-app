import SwiftUI

/// Manages a standalone NSWindow for settings.
/// LSUIElement menu bar apps need activation policy workaround for keyboard input.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(appState: AppState, updaterViewModel: UpdaterViewModel) {
        // Temporarily become .accessory so the window can receive keyboard input.
        // LSUIElement apps default to .prohibited which blocks all key events.
        NSApp.setActivationPolicy(.accessory)

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .environment(appState)
            .environmentObject(updaterViewModel)

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Vibe Usage Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    // Revert activation policy when settings window closes
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
    }
}
