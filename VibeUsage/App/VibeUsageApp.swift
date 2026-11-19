import SwiftUI
import AppKit

@main
struct VibeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // AppDelegate owns the menu bar status item and popover panel.
        // The Settings scene placeholder satisfies the App protocol; Settings itself
        // is still presented through SettingsWindowController.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let updaterViewModel = UpdaterViewModel()
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ActivationCoordinator.shared.applyDockPreference()
        appState.initialize()
        menuBarController = MenuBarController(appState: appState, updaterViewModel: updaterViewModel)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.menuBarController?.presentPanelForAppActivation()
        }
    }

    // No `applicationWillResignActive` dismissal: the app also resigns active
    // for its own reasons (closing the Settings window flips the activation
    // policy back when the Dock icon is hidden, which deactivates the app), and
    // that used to take the popover down together with Settings.
    // `MenuBarController` closes the popover when `NSWorkspace` reports that
    // *another* application took focus — the actual "user switched away" signal.

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarController?.presentPanelForAppActivation()
        return true
    }
}
