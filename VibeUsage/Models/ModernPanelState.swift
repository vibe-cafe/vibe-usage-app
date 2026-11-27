import Foundation
import Observation

/// Which quotas a 「刷新额度」 click reads again.
enum QuotaRefreshScope: Equatable {
    /// 概览: every enabled subscription.
    case all
    /// One subscription's detail.
    case one(ProviderRateLimit.Provider)
}

/// What the new panel is showing. It lives outside the view because closing
/// the panel only hides it: the hosting view, and any `@State` in it, is
/// reused on the next open. `MenuBarController` calls `panelDidOpen()` on every
/// real open (not when an already visible panel is brought forward), which
/// puts the panel back on 概览, cost and collapsed.
///
/// The selected subscription here is a stand-in carrier; the usage rules
/// (#105) bring the full selected-subscription state.
@Observable
@MainActor
final class ModernPanelState {
    /// The subscription opened from its round button; nil is 概览.
    var selectedSubscription: ProviderRateLimit.Provider?
    /// The big number of 近期消耗.
    var hero: ChartMode = .cost
    /// 展开详情 / 收起详情.
    var detailsExpanded = false

    func panelDidOpen() {
        selectedSubscription = nil
        hero = .cost
        detailsExpanded = false
    }

    /// The subscription whose detail is on screen: the only enabled one
    /// (there is no 概览 for a single subscription), else the selected one
    /// while it is still enabled.
    func focusedSubscription(
        enabled: [ProviderRateLimit.Provider]
    ) -> ProviderRateLimit.Provider? {
        if enabled.count == 1 { return enabled[0] }
        guard let selectedSubscription, enabled.contains(selectedSubscription) else { return nil }
        return selectedSubscription
    }

    /// What 「刷新额度」 reads: this subscription in its detail, everything on
    /// 概览, and nothing (no button) without an enabled subscription.
    func quotaRefreshScope(enabled: [ProviderRateLimit.Provider]) -> QuotaRefreshScope? {
        guard !enabled.isEmpty else { return nil }
        return focusedSubscription(enabled: enabled).map(QuotaRefreshScope.one) ?? .all
    }
}
