import SwiftUI
import Sparkle

/// Bridges Sparkle's SPUUpdater to SwiftUI.
/// Only activates when running inside a real .app bundle —
/// `swift run` has no Info.plist so Sparkle would fail.
@MainActor
final class UpdaterViewModel: ObservableObject {
    private var updaterController: SPUStandardUpdaterController?

    @Published var canCheckForUpdates = false

    /// Whether Sparkle is available (real .app bundle with SUFeedURL).
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
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = controller

        // Observe canCheckForUpdates via KVO and publish to SwiftUI.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
