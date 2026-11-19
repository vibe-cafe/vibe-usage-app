import SwiftUI

/// Manages a standalone NSWindow for settings.
/// Settings is kept as an explicit NSWindow so it can coexist cleanly with the
/// custom menu-bar panel and Sparkle's normal AppKit dialogs.
///
/// The window is the standard macOS settings layout: an `NSTabViewController`
/// in toolbar style, one toolbar tab per `SettingsTab` case, each hosting its
/// SwiftUI page.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var tabViewController: NSTabViewController?
    private let navigation = SettingsNavigation()
    /// The tab Settings reopens on when the caller names none.
    private var lastTab: SettingsTab = .general

    /// - Parameters:
    ///   - tab: the page to show; `nil` keeps the current (or last) one.
    ///   - quotaProvider: the product 订阅配额 should select.
    func show(
        appState: AppState,
        updaterViewModel: UpdaterViewModel,
        tab: SettingsTab? = nil,
        quotaProvider: ProviderRateLimit.Provider? = nil
    ) {
        // ActivationCoordinator remains the single policy touch point; while
        // Settings is visible it keeps the app `.regular` even if the user
        // has hidden the Dock icon.
        ActivationCoordinator.shared.settingsDidOpen()
        NSApp.activate(ignoringOtherApps: true)

        if let quotaProvider {
            navigation.quotaProvider = quotaProvider
        }

        if let window, window.isVisible {
            if let tab { select(tab) }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar
        let navigation = navigation
        for item in Self.makeTabViewItems(content: { tab in
            let controller = NSHostingController(
                rootView: SettingsTabContent(tab: tab)
                    .environment(appState)
                    .environment(navigation)
                    .environmentObject(updaterViewModel)
            )
            // Every page reports the same fixed size, so a tab switch has no
            // size to animate to.
            controller.sizingOptions = [.preferredContentSize]
            return controller
        }) {
            tabViewController.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabViewController)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The tab view controller does not size the window from its pages.
        window.setContentSize(SettingsTab.contentSize)

        self.tabViewController = tabViewController
        self.window = window
        select(tab ?? lastTab)

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// One toolbar tab per manifest case, in manifest order. The tab's
    /// identifier is the case's raw value, so selection maps back to the case.
    static func makeTabViewItems(
        content: (SettingsTab) -> NSViewController
    ) -> [NSTabViewItem] {
        SettingsTab.allCases.map { tab in
            let controller = content(tab)
            // NSTabViewController propagates the selected child's title to the
            // window, so the title bar names the open page.
            controller.title = tab.title
            let item = NSTabViewItem(viewController: controller)
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
            return item
        }
    }

    private func select(_ tab: SettingsTab) {
        guard let tabViewController,
              let index = SettingsTab.allCases.firstIndex(of: tab)
        else { return }
        tabViewController.selectedTabViewItemIndex = index
    }

    func windowWillClose(_ notification: Notification) {
        if let tabViewController,
           SettingsTab.allCases.indices.contains(tabViewController.selectedTabViewItemIndex) {
            lastTab = SettingsTab.allCases[tabViewController.selectedTabViewItemIndex]
        }
        ActivationCoordinator.shared.settingsDidClose()
    }
}
