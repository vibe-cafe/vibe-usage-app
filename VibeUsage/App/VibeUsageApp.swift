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
    /// Set for a login-item launch (`LoginLaunch`): the first activation in
    /// this window does not open the dashboard by itself.
    private var activationPanelQuietUntil: Date?
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The open-application event is current only while launching.
        launchedAsLoginItem = LoginLaunch.isLoginItemLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ActivationCoordinator.shared.applyDockPreference()
        if launchedAsLoginItem {
            // Start quietly: the proxy client may not be up yet, and quotas
            // are read only when the user opens the dashboard.
            debugLog("[launch] login item launch — no automatic dashboard, first sync in \(Int(LoginLaunch.firstSyncDelay))s")
            activationPanelQuietUntil = Date().addingTimeInterval(LoginLaunch.quietActivationWindow)
            appState.launchSyncDelay = LoginLaunch.firstSyncDelay
        }
        appState.initialize()
        menuBarController = MenuBarController(appState: appState, updaterViewModel: updaterViewModel)
        #if DEBUG
        // Local UI checks and preview builds: open Settings right after launch.
        if ProcessInfo.processInfo.environment["VIBE_USAGE_SETTINGS_UI_TEST"] == "1" {
            SettingsWindowController.shared.show(appState: appState, updaterViewModel: updaterViewModel)
        }
        #endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let quietUntil = activationPanelQuietUntil {
            activationPanelQuietUntil = nil
            if Date() < quietUntil { return }
        }
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
