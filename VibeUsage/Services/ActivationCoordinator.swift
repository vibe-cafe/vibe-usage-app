import AppKit

/// Centralizes `NSApplication.activationPolicy` and Dock presentation
/// management across the menu-bar popup and the Settings window.
///
/// Vibe Usage is now a regular Dock app while still keeping its menu-bar item,
/// so the lowest policy is `.regular`. The coordinator still owns the call site
/// so popup/settings transitions cannot fight each other.
///
/// Without coordination, one surface closing would reset the policy to
/// a lower state while the other was still visible.
@MainActor
final class ActivationCoordinator {
    static let shared = ActivationCoordinator()

    private var popupVisible = false
    private var settingsVisible = false
    weak var appState: AppState?

    /// Invoked whenever Settings visibility changes. MenuBarController uses this
    /// to lower the popup's window level while Settings is visible, so standard
    /// z-ordering lets Settings come to the front on click.
    var onSettingsVisibilityChange: ((Bool) -> Void)?

    /// Invoked while Sparkle is showing its modal update window. `true` =
    /// about to show (lower the popup so Sparkle's normal-level window isn't
    /// buried under the `.popUpMenu` panel), `false` = dismissed (restore).
    /// We deliberately do NOT close the popup — it stays open behind/around
    /// the update dialog, just no longer on top of it.
    var onUpdateModalVisibilityChange: ((Bool) -> Void)?

    private init() {}

    func configure(with appState: AppState) {
        self.appState = appState
    }

    func popupDidOpen() {
        popupVisible = true
        reconcile()
    }

    func popupDidClose() {
        popupVisible = false
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

    /// Applies the user's Dock visibility preference, both at launch and
    /// whenever the preference may change at runtime (e.g. when Settings
    /// closes). Keeps activation policy and Dock icon in sync so toggling
    /// "在 Dock 中显示" doesn't leave one set while the other is unset.
    func configureDockPresentation() {
        let showInDock = appState?.showInDock != false
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }

        if showInDock, let image = loadDockIcon() {
            NSApp.applicationIconImage = image
        } else {
            NSApp.applicationIconImage = nil
        }
    }

    private func reconcile() {
        configureDockPresentation()
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
