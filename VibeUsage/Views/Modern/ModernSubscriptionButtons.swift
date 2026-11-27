import SwiftUI

/// The round buttons of the 概览 row (133): one per enabled subscription, in
/// the order Settings keeps. Clicking one opens that subscription; dragging
/// one reorders the shared order (`moveQuotaProduct`, the same call as the
/// Settings table and the classic tab strip). The view takes the row's free
/// width, so dropping past the last button moves a subscription to the end.
struct ModernSubscriptionButtons: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let display = appState.quotaPanelDisplay(now: context.date)
            HStack(spacing: 6) {
                ForEach(display.buttons, id: \.provider) { subscription in
                    ModernSubscriptionButton(
                        subscription: subscription,
                        isSelected: display.detail?.provider == subscription.provider
                    ) {
                        appState.modernPanel.selectedSubscription = subscription.provider
                    }
                    .draggable(subscription.provider.rawValue) {
                        ModernRoundButtonFace(
                            provider: subscription.provider,
                            remaining: subscription.buttonRemaining,
                            isSelected: false,
                            showsDot: subscription.showsWhiteDot
                        )
                    }
                    .dropDestination(for: String.self) { items, _ in
                        move(items, before: subscription.provider)
                    }
                }
                Color.clear
                    .frame(minWidth: 12, maxWidth: .infinity, minHeight: ModernRoundButtonFace.size)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        move(items, before: nil)
                    }
            }
        }
    }

    private func move(_ items: [String], before target: ProviderRateLimit.Provider?) -> Bool {
        guard let raw = items.first, let dragged = ProviderRateLimit.Provider(rawValue: raw),
              appState.isQuotaProviderSelected(dragged)
        else { return false }
        appState.moveQuotaProduct(dragged, before: target)
        return true
    }
}

/// One round button. The pointer brightens its mark; the native tooltip says
/// name, plan and state (「Codex Plus · 快用完」, 「Cursor · 读取已暂停」).
struct ModernSubscriptionButton: View {
    let subscription: QuotaSubscriptionDisplay
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ModernRoundButtonFace(
                provider: subscription.provider,
                remaining: subscription.buttonRemaining,
                isSelected: isSelected,
                showsDot: subscription.showsWhiteDot,
                isHovered: isHovered
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var help: String {
        let name = [subscription.provider.displayName, subscription.planLabel].compactMap { $0 }.joined(separator: " ")
        return "\(name) · \(subscription.buttonStatus)"
    }
}
