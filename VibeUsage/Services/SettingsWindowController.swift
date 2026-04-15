import SwiftUI

/// Manages a standalone NSWindow for settings.
/// LSUIElement menu bar apps need activation policy workaround for keyboard input.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(appState: AppState, updaterViewModel: UpdaterViewModel) {
        // .regular gives Settings normal-window behavior (click-to-front, Cmd-Tab,
        // full key handling). ActivationCoordinator reconciles so a later popup
        // close won't drop the app back to .prohibited and kill this window.
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
        window.title = "Vibe Usage Settings"
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
