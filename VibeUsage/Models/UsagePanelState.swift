import Foundation

extension ProviderRateLimit.Provider {
    /// Usage is attributed to the tool, irrespective of its billing account.
    var usageSource: String { self == .opencodeGo ? "opencode" : rawValue }
}

extension FilterState {
    mutating func clearUsagePanelFilters() {
        sources.removeAll()
        models.removeAll()
        hostnames.removeAll()
    }
}

struct UsagePanelFilters: Equatable {
    var sources: Set<String> = []
    var models: Set<String> = []
    var hostnames: Set<String> = []

    func includes(_ bucket: UsageBucket, modelName: String) -> Bool {
        (sources.isEmpty || sources.contains(bucket.source))
            && (models.isEmpty || models.contains(modelName))
            && (hostnames.isEmpty || hostnames.contains(bucket.hostname))
    }
}

/// Control state owned by the new panel, independent of the classic tab and chart.
struct UsagePanelState {
    var selectedSubscription: ProviderRateLimit.Provider?
    var hero: ChartMode = .cost
    var detailsExpanded = false
    private(set) var usesCNY = false
    private(set) var usesChineseTokens = false
    private var distributionMetrics: [UsageRanking.Dimension: MetricMode] = [:]

    subscript(metricFor dimension: UsageRanking.Dimension) -> MetricMode {
        get { distributionMetrics[dimension, default: .tokens] }
        set { distributionMetrics[dimension] = newValue }
    }

    func effectiveFilters(_ manual: FilterState, enabledSubscriptions: [ProviderRateLimit.Provider]) -> UsagePanelFilters {
        var result = UsagePanelFilters(sources: manual.sources, models: manual.models, hostnames: manual.hostnames)
        if enabledSubscriptions.count > 1, let selectedSubscription, enabledSubscriptions.contains(selectedSubscription) {
            result.sources = [selectedSubscription.usageSource]
        }
        return result
    }

    mutating func toggleHeroUnit() {
        switch hero {
        case .cost: usesCNY.toggle()
        case .token: usesChineseTokens.toggle()
        case .activeTime: break
        }
    }

    func formatCost(_ usd: Double) -> String {
        usesCNY ? Formatters.formatCnyCost(usd) : Formatters.formatCost(usd)
    }

    func formatTokens(_ tokens: Int) -> String {
        usesChineseTokens ? Formatters.formatPanelChineseTokens(tokens) : Formatters.formatNumber(tokens)
    }

    /// Called on presentation, including when the panel reuses its hosting view.
    mutating func panelDidOpen() {
        selectedSubscription = nil
        hero = .cost
        detailsExpanded = false
    }
}
