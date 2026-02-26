import SwiftUI

/// Manages a standalone NSWindow for settings.
/// SwiftUI's Settings scene and Window scene don't work reliably in LSUIElement menu bar apps,
/// so we create the window manually.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(appState: AppState) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .environment(appState)

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Vibe Usage Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
