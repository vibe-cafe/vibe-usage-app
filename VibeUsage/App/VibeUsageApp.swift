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
        appState.initialize()
        ActivationCoordinator.shared.configure(with: appState)
        ActivationCoordinator.shared.configureDockPresentation()
        menuBarController = MenuBarController(appState: appState, updaterViewModel: updaterViewModel)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarController?.presentPanel()
        return true
    }
}
