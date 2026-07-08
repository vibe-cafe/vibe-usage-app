import AppKit

/// Centralizes `NSApplication.activationPolicy` and Dock presentation
/// management across the menu-bar popup and the Settings window.
///
/// The policy follows the user's "show in Dock" preference (`.regular` when
/// shown, `.accessory` when hidden), with one exception: while the Settings
/// window is visible the app is always promoted to `.regular`, so Settings
/// keeps a main menu and a Cmd-Tab entry even when the Dock icon is off.
/// The coordinator owns the only `setActivationPolicy` call site so
/// popup/settings transitions and preference changes cannot fight each other.
@MainActor
final class ActivationCoordinator {
    static let shared = ActivationCoordinator()

    private var settingsVisible = false
    private var updateModalVisible = false

    /// Policy last applied by `reconcile()`. Policy and Dock icon are only
    /// touched on actual transitions — reassigning `applicationIconImage`
    /// forces a Dock redraw even when nothing changed. `nil` until the first
    /// reconcile so launch always applies, including dev runs without a
    /// bundle where the initial policy is already `.regular`.
    private var appliedPolicy: NSApplication.ActivationPolicy?

    private lazy var dockIcon: NSImage? = loadDockIcon()

    /// Invoked whenever Settings visibility changes. MenuBarController uses this
    /// to lower the popup's window level while Settings is visible, so standard
    /// z-ordering lets Settings come to the front on click.
    var onSettingsVisibilityChange: ((Bool) -> Void)?

    /// Invoked around a Sparkle update session. `true` = update UI about to
    /// show — the "checking" progress window, the update-available window, or
    /// an alert (lower the popup so Sparkle's normal-level windows aren't
    /// buried under the `.popUpMenu` panel); `false` = session finished
    /// (restore). We deliberately do NOT close the popup — it stays open
    /// behind/around the update dialog, just no longer on top of it.
    var onUpdateModalVisibilityChange: ((Bool) -> Void)?

    private init() {}

    /// Popup visibility doesn't currently influence the policy; the hooks stay
    /// so surfaces keep reporting transitions through the coordinator.
    func popupDidOpen() {
        reconcile()
    }

    func popupDidClose() {
        reconcile()
    }

    func settingsDidOpen() {
        let changed = !settingsVisible
        settingsVisible = true
        reconcile()
        if changed { onSettingsVisibilityChange?(true) }
    }

    func settingsDidClose() {
        let changed = settingsVisible
        settingsVisible = false
        reconcile()
        if changed { onSettingsVisibilityChange?(false) }
    }

    func updateModalVisibilityDidChange(_ visible: Bool) {
        updateModalVisible = visible
        onUpdateModalVisibilityChange?(visible)
    }

    var canPresentDashboardForAppActivation: Bool {
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        return showInDock && !settingsVisible && !updateModalVisible
    }

    var canDismissDashboardForAppDeactivation: Bool {
        !settingsVisible && !updateModalVisible
    }

    /// Applies the user's Dock visibility preference: at launch (before any
    /// other startup work, so a hidden Dock icon never flashes) and whenever
    /// `AppState.showInDock` changes. While Settings is open the change is
    /// deferred by the reconcile arbitration until the window closes, which
    /// is what the settings footer promises.
    func applyDockPreference() {
        reconcile()
    }

    private func reconcile() {
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        let policy: NSApplication.ActivationPolicy = (showInDock || settingsVisible) ? .regular : .accessory
        guard policy != appliedPolicy else { return }
        appliedPolicy = policy

        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
        NSApp.applicationIconImage = policy == .regular ? dockIcon : nil
    }

    private func loadDockIcon() -> NSImage? {
        let appIconPath = "Assets.xcassets/AppIcon.appiconset/icon_512x512"
        if let url = Bundle.appResources.url(forResource: appIconPath, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 128, height: 128)
            return image
        }

        if let image = NSImage(named: "AppIcon") {
            return image
        }

        if let url = Bundle.appResources.url(forResource: "menubar-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 128, height: 128)
            return image
        }

        return nil
    }
}
