import SwiftUI

/// The 订阅配额 tab strip: one icon per product, the settings icon pinned to the
/// trailing edge.
///
/// The strip is an index into the card row: clicking a tab asks the row to
/// scroll to that product (`onSelect`), and the highlighted tab follows the row
/// as it scrolls (`activeProvider`) — so the strip never claims a product is on
/// screen when it is not. Products whose monitoring is on come first and keep
/// their brand color; products that are off stay visible after them, desaturated
/// (the strip is the product catalog, not a summary of the selection). Tabs are
/// draggable: the order is persisted (`QuotaSelectionPreferences.orderKey`), and
/// because enabled products render as their own group, a cross-group drop lands
/// inside the dragged product's group instead of breaking the "enabled first"
/// rule.
struct QuotaTabStripView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel

    /// The product whose card currently leads the row.
    let activeProvider: ProviderRateLimit.Provider
    /// Jump the card row to this product.
    let onSelect: (ProviderRateLimit.Provider) -> Void

    private static let tabSize: CGFloat = 30
    private static let tabSpacing: CGFloat = 6

    var body: some View {
        HStack(spacing: Self.tabSpacing) {
            ForEach(appState.quotaTabOrder, id: \.self) { provider in
                tab(provider)
            }
            // Dropping past the last icon moves the product to the end of its
            // group — dragging onto the final tab can only mean "before it".
            Color.clear
                .frame(minWidth: 12, maxWidth: .infinity, minHeight: Self.tabSize, maxHeight: Self.tabSize)
                .dropDestination(for: String.self) { items, _ in
                    move(items, before: nil)
                }
            settingsIcon
        }
        .frame(height: Self.tabSize)
    }

    // MARK: - Tabs

    private func tab(_ provider: ProviderRateLimit.Provider) -> some View {
        let isActive = activeProvider == provider
        let isEnabled = appState.isQuotaProviderSelected(provider)
        return Button {
            onSelect(provider)
        } label: {
            ProviderIcon(provider: provider)
                .frame(width: 20, height: 20)
                .padding(5)
                .background(isActive ? Color(white: 0.17) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isActive ? Color(white: 0.34) : Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))
                // Off products keep their slot but lose their color: the icon
                // itself carries "on / off", so a greyed tab is a product the
                // user can look at (and enable) rather than one that is gone.
                .saturation(isEnabled ? 1 : 0)
                .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .help(tabHelp(provider, isEnabled: isEnabled))
        .accessibilityLabel(provider.displayName)
        .draggable(provider.rawValue) {
            ProviderIcon(provider: provider)
                .frame(width: 20, height: 20)
                .padding(5)
        }
        .dropDestination(for: String.self) { items, _ in
            move(items, before: provider)
        }
    }

    private func tabHelp(_ provider: ProviderRateLimit.Provider, isEnabled: Bool) -> String {
        let status = appState.quotaProductStatusText(
            appState.quotaProducts.first { $0.provider == provider }
                ?? QuotaProduct(provider: provider, availability: .ready, isDetected: false)
        )
        return isEnabled ? "\(provider.displayName) · \(status)" : "\(provider.displayName) · \(status) · 未启用"
    }

    // MARK: - Reorder

    private func move(_ items: [String], before target: ProviderRateLimit.Provider?) -> Bool {
        guard let raw = items.first,
              let dragged = ProviderRateLimit.Provider(rawValue: raw)
        else { return false }
        appState.moveQuotaProduct(dragged, before: target)
        return true
    }

    // MARK: - Settings

    /// A bare icon at the trailing edge, outside the drag order: the way to the
    /// full 订阅配额 settings (toggles, per-product status, 「重新检测本机产品」).
    private var settingsIcon: some View {
        Button {
            SettingsWindowController.shared.show(appState: appState, updaterViewModel: updaterViewModel)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(Color(white: 0.62))
                .frame(width: Self.tabSize, height: Self.tabSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开订阅配额设置")
        .accessibilityLabel("订阅配额设置")
    }
}
