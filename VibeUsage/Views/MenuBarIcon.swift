import SwiftUI

/// Menu bar icon that reflects sync status
struct MenuBarIcon: View {
    let state: SyncStatus

    var body: some View {
        switch state {
        case .idle, .success:
            Image(systemName: "chart.bar.fill")
                .symbolRenderingMode(.hierarchical)
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolRenderingMode(.hierarchical)
        case .error:
            Image(systemName: "chart.bar.fill")
                .symbolRenderingMode(.hierarchical)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
        }
    }
}
