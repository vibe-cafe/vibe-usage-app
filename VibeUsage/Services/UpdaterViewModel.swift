import SwiftUI
import Sparkle

/// Bridges Sparkle's SPUUpdater to SwiftUI.
/// Only activates when running inside a real .app bundle —
/// `swift run` has no Info.plist so Sparkle would fail.
@MainActor
final class UpdaterViewModel: ObservableObject {
    private var updaterController: SPUStandardUpdaterController?
    private let delegateProxy = UpdaterDelegateProxy()

    @Published var canCheckForUpdates = false

    /// The appcast item for a pending update, or nil if none has been discovered
    /// (or the user skipped / installed it). Drives the in-popover update banner.
    @Published var availableUpdate: SUAppcastItem?

    var isAvailable: Bool { updaterController != nil }

    init() {
        // Only initialize Sparkle inside a proper .app bundle.
        // swift run / debug builds without a bundle lack Info.plist,
        // which causes Sparkle to block or crash.
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              Bundle.main.infoDictionary?["SUFeedURL"] != nil else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegateProxy,
            userDriverDelegate: delegateProxy
        )
        self.updaterController = controller

        delegateProxy.onFoundValidUpdate = { [weak self] item in
            Task { @MainActor in self?.availableUpdate = item }
        }
        delegateProxy.onDidNotFindUpdate = { [weak self] in
            Task { @MainActor in self?.availableUpdate = nil }
        }
        delegateProxy.onUserChoice = { [weak self] choice in
            Task { @MainActor in
                guard let self else { return }
                // .install → about to relaunch; .skip → user opted out for this
                // version. Either way we clear the banner. .dismiss keeps it so
                // the user can act later from the popover.
                switch choice {
                case .install, .skip:
                    self.availableUpdate = nil
                case .dismiss:
                    break
                @unknown default:
                    self.availableUpdate = nil
                }
            }
        }

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}

/// Non-isolated NSObject proxy so `SPUStandardUpdaterController` can call back
/// from Sparkle's internal queues. Forwards to closures that hop to the main
/// actor before touching UpdaterViewModel state.
private final class UpdaterDelegateProxy: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var onFoundValidUpdate: ((SUAppcastItem) -> Void)?
    var onDidNotFindUpdate: (() -> Void)?
    var onUserChoice: ((SPUUserUpdateChoice) -> Void)?

    // Sparkle calls these around its modal update window so we can move attached
    // windows out of the way. We don't hide the popup — just signal the
    // coordinator to lower its level so the dialog shows above it. `nonisolated`
    // because the protocol isn't @MainActor-annotated; we hop to the main actor
    // before touching coordinator state (same pattern as the other callbacks).
    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in ActivationCoordinator.shared.onUpdateModalVisibilityChange?(true) }
    }

    nonisolated func standardUserDriverDidShowModalAlert() {
        Task { @MainActor in ActivationCoordinator.shared.onUpdateModalVisibilityChange?(false) }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onFoundValidUpdate?(item)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onDidNotFindUpdate?()
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        onUserChoice?(choice)
    }
}
