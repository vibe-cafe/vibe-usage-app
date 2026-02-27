import SwiftUI
import Sparkle

/// Bridges Sparkle's SPUUpdater to SwiftUI.
/// Observes `canCheckForUpdates` so the "Check for Updates" button
/// disables itself while an update check is already in progress.
@MainActor
final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    init() {
        // Create the updater controller.
        // startingUpdater: true — starts the update cycle automatically on launch.
        // updaterDelegate / userDriverDelegate: nil — use defaults.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Observe canCheckForUpdates via KVO and publish to SwiftUI.
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
