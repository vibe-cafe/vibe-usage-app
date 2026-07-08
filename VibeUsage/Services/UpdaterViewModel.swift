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
        guard let updaterController else { return }
        // Sparkle's "Checking for updates…" progress window appears immediately —
        // BEFORE any user-driver delegate callback fires — so lower the popup
        // now rather than waiting for standardUserDriverWillHandleShowingUpdate.
        // The matching restore comes from standardUserDriverWillFinishUpdateSession
        // (every Sparkle session ends by dismissing the update installation).
        ActivationCoordinator.shared.updateModalVisibilityDidChange(true)
        updaterController.checkForUpdates(nil)
    }
}

/// Non-isolated NSObject proxy so `SPUStandardUpdaterController` can call back
/// from Sparkle's internal queues. Forwards to closures that hop to the main
/// actor before touching UpdaterViewModel state.
private final class UpdaterDelegateProxy: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var onFoundValidUpdate: ((SUAppcastItem) -> Void)?
    var onDidNotFindUpdate: (() -> Void)?
    var onUserChoice: ((SPUUserUpdateChoice) -> Void)?

    // Sparkle's update UI (the "update available" window, progress windows,
    // and alerts) lives at normal window level, which the popup's `.popUpMenu`
    // panel would bury. These two callbacks bracket the whole update session:
    // WillHandleShowingUpdate fires right before the update window appears
    // (both user-initiated and scheduled checks); WillFinishUpdateSession fires
    // when the session ends for ANY reason (installed / skipped / dismissed /
    // error / no update found). We don't hide the popup — just signal the
    // coordinator to lower its level so Sparkle's windows show above it.
    // NOTE: standardUserDriverWill/DidShowModalAlert are NOT sufficient here —
    // they only wrap NSAlert runModal (errors, "no update"), never the main
    // update window. `nonisolated` because the protocol isn't
    // @MainActor-annotated; we hop to the main actor before touching
    // coordinator state (same pattern as the other callbacks).
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in ActivationCoordinator.shared.updateModalVisibilityDidChange(true) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in ActivationCoordinator.shared.updateModalVisibilityDidChange(false) }
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
