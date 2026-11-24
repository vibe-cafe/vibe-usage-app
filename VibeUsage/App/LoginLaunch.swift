import AppKit
import ServiceManagement

/// Whether this launch is macOS starting the app as a login item, so the app
/// can start quietly: no dashboard popping up on its own and no first sync
/// in the first minutes, while the user's proxy client may not be running
/// yet (network-privacy principle, workspace AGENTS.md).
///
/// macOS marks a login-item launch on the open-application Apple Event
/// (`keyAELaunchedAsLogInItem`). Whether that mark is set for a
/// `SMAppService.mainApp` registration is not documented, so a launch with
/// the login item enabled within the first minutes after the system started
/// counts too. A manual launch in that window only loses the automatic
/// dashboard on its first activation (a Dock or menu-bar click still opens
/// it) and waits two minutes for its first sync.
enum LoginLaunch {
    /// The first sync of a login launch waits this long.
    static let firstSyncDelay: TimeInterval = 120
    /// An activation this soon after a login launch does not open the
    /// dashboard by itself.
    static let quietActivationWindow: TimeInterval = 30
    static let bootWindow: TimeInterval = 300

    static func isLoginItemLaunch(
        event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent,
        loginItemEnabled: Bool = SMAppService.mainApp.status == .enabled,
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        if let event, event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
               == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        return loginItemEnabled && systemUptime < bootWindow
    }
}
