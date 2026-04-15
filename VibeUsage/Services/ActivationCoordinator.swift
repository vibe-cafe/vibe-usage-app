import AppKit

/// Centralizes `NSApplication.activationPolicy` management across the menu-bar
/// popup and the Settings window.
///
/// Each surface has different needs:
///   - Popup: `.accessory` so TextFields can receive key events.
///   - Settings: `.regular` so the window behaves like a normal app window
///     (click-to-front, Cmd-Tab, proper key handling).
///   - Neither: `.prohibited` (true LSUIElement state).
///
/// Without coordination, one surface closing would reset the policy to
/// `.prohibited` even while the other was still visible — in particular, closing
/// the popup would drop the app out of `.regular`, which AppKit treats as a
/// request to tear down the Settings window along with it.
@MainActor
final class ActivationCoordinator {
    static let shared = ActivationCoordinator()

    private var popupVisible = false
    private var settingsVisible = false

    /// Invoked whenever Settings visibility changes. MenuBarController uses this
    /// to lower the popup's window level while Settings is visible, so standard
    /// z-ordering lets Settings come to the front on click.
    var onSettingsVisibilityChange: ((Bool) -> Void)?

    private init() {}

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

    private func reconcile() {
        let policy: NSApplication.ActivationPolicy
        if settingsVisible {
            policy = .regular
        } else if popupVisible {
            policy = .accessory
        } else {
            policy = .prohibited
        }
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}
