import SwiftUI
import AppKit

/// Menu bar icon that reflects sync status.
/// Loads PNG directly from bundle (SPM `swift build` doesn't compile xcassets).
struct MenuBarIcon: View {
    let state: SyncStatus

    private static let iconImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "menubar-icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        switch state {
        case .idle, .success:
            iconView
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolRenderingMode(.hierarchical)
        case .error:
            iconView
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let nsImage = Self.iconImage {
            Image(nsImage: nsImage)
        } else {
            // Fallback if PNG not found
            Image(systemName: "chart.bar.fill")
                .symbolRenderingMode(.hierarchical)
        }
    }
}
