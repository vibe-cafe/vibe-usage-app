import SwiftUI

struct SummaryCardsView: View {
    @Environment(AppState.self) private var appState

    private var filtered: [UsageBucket] {
        let cutoff = appState.timeRange.startCutoff
        return appState.buckets.filter { bucket in
            if let cutoff, let date = bucket.date, date < cutoff { return false }
            let f = appState.filters
            if !f.sources.isEmpty && !f.sources.contains(bucket.source) { return false }
            if !f.models.isEmpty && !f.models.contains(bucket.model) { return false }
            if !f.projects.isEmpty && !f.projects.contains(bucket.project) { return false }
            if !f.hostnames.isEmpty && !f.hostnames.contains(bucket.hostname) { return false }
            return true
        }
    }

    private var totalCost: Double {
        filtered.reduce(0) { $0 + ($1.estimatedCost ?? 0) }
    }

    private var totalTokens: Int {
        filtered.reduce(0) { $0 + $1.computedTotal }
    }

    private var totalCachedInputTokens: Int {
        filtered.reduce(0) { $0 + $1.cachedInputTokens }
    }

    private var filteredSessions: [UsageSession] {
        appState.filteredSessions
    }

    private var totalActiveSeconds: Int {
        filteredSessions.reduce(0) { $0 + $1.activeSeconds }
    }

    var body: some View {
        let palette = appState.appTheme.palette

        HStack(alignment: .top, spacing: 8) {
            StatCard(label: "预估费用", value: Formatters.formatCost(totalCost), color: palette.accent)
            StatCard(label: "输入+输出 Token", value: Formatters.formatNumber(totalTokens))
            StatCard(label: "缓存 Token", value: Formatters.formatNumber(totalCachedInputTokens))
            StatCard(label: "活跃时长", value: Formatters.formatDuration(totalActiveSeconds), color: palette.secondaryAccent)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatCard: View {
    @Environment(AppState.self) private var appState
    let label: String
    let value: String
    var color: Color?

    // Reserve fixed line-box heights so all cards render at exactly the same height,
    // even when minimumScaleFactor shrinks the value glyphs in narrower columns.
    private let labelHeight: CGFloat = 14   // 12pt font
    private let valueHeight: CGFloat = 24   // 20pt font

    var body: some View {
        let palette = appState.appTheme.palette

        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(height: labelHeight, alignment: .leading)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(color ?? palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: valueHeight, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 13)
        .background(palette.card)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}
