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
/// The usage controls (#105) are `usage`; the properties below read and write
/// the same values, so there is one selected subscription, one hero and one
/// 展开详情 for the whole panel. Units and the distribution cards' metrics
/// (stored apart, below) survive reopening (they live for the app session).
@Observable
@MainActor
final class ModernPanelState {
    /// Selected subscription, hero, units and 展开详情.
    var usage = UsagePanelState()
    /// Counts real opens, so views that keep a snapshot rebuild it against a
    /// fresh clock on every open.
    private(set) var presentation = 0
    /// 近期消耗's filter menu. Here rather than in the view so the panel's
    /// Escape handling (`MenuBarController`) can close it first.
    let filterMenu = UsageFilterMenuState()

    /// The subscription opened from its round button; nil is 概览.
    var selectedSubscription: ProviderRateLimit.Provider? {
        get { usage.selectedSubscription }
        set { usage.selectedSubscription = newValue }
    }

    /// The big number of 近期消耗.
    var hero: ChartMode {
        get { usage.hero }
        set { usage.hero = newValue }
    }

    /// 展开详情 / 收起详情.
    var detailsExpanded: Bool {
        get { usage.detailsExpanded }
        set { usage.detailsExpanded = newValue }
    }

    /// Token / 费用 of each 展开详情 distribution card. Unlike the rest, it
    /// is not reset on open: it lasts for the app session (#105). Kept apart
    /// from `usage`, so switching a card's metric does not touch what the
    /// figures are worked out from (the details snapshot is not rebuilt).
    private var distributionMetrics: [UsageRanking.Dimension: MetricMode] = [:]

    subscript(metricFor dimension: UsageRanking.Dimension) -> MetricMode {
        get { distributionMetrics[dimension, default: .tokens] }
        set { distributionMetrics[dimension] = newValue }
    }

    /// What every usage number of the new panel counts (近期消耗 and the
    /// details cards): the manual terminal, tool and model filters, with the
    /// tool replaced by the selected subscription's (#105 rule).
    func usageFilters(_ manual: FilterState, enabled: [ProviderRateLimit.Provider]) -> UsagePanelFilters {
        usage.effectiveFilters(manual, enabledSubscriptions: enabled)
    }

    func panelDidOpen() {
        usage.panelDidOpen()
        filterMenu.close()
        presentation &+= 1
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
