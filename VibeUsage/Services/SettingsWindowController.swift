import SwiftUI

/// Manages a standalone NSWindow for settings.
/// Settings is kept as an explicit NSWindow so it can coexist cleanly with the
/// custom menu-bar panel and Sparkle's normal AppKit dialogs.
///
/// The window hosts `SettingsRootView`: a sidebar of categories plus the
/// 提供商 group, and the selected page beside it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    /// Lives as long as the app, so a reopened window returns to the last page.
    private let navigation = SettingsNavigation()

    /// - Parameter destination: the page to show; `nil` keeps the current (or
    ///   last) one.
    func show(
        appState: AppState,
        updaterViewModel: UpdaterViewModel,
        destination: SettingsDestination? = nil
    ) {
        // ActivationCoordinator remains the single policy touch point; while
        // Settings is visible it keeps the app `.regular` even if the user
        // has hidden the Dock icon.
        ActivationCoordinator.shared.settingsDidOpen()
        NSApp.activate(ignoringOtherApps: true)

        if let destination {
            navigation.selection = destination
        }

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsRootView()
                .environment(appState)
                .environment(navigation)
                .environmentObject(updaterViewModel)
        )
        // The page title (`navigationTitle`) becomes the window title.
        hostingController.sceneBridgingOptions = [.title, .toolbars]

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(SettingsRootView.contentSize)
        // `navigationTitle` keeps the title current once the window is up;
        // it does not set the first one.
        window.title = (navigation.selection ?? .category(.general)).title
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        ActivationCoordinator.shared.settingsDidClose()
    }
}
