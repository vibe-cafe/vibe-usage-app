import SwiftUI

struct SummaryCardsView: View {
    @Environment(AppState.self) private var appState

    private var filtered: [UsageBucket] {
        appState.buckets.filter { bucket in
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

    private var totalDurationSeconds: Int {
        filteredSessions.reduce(0) { $0 + $1.durationSeconds }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatCard(label: "预估费用", value: Formatters.formatCost(totalCost), color: Color(red: 0.2, green: 0.8, blue: 0.5))
            StatCard(label: "总 Token", value: Formatters.formatNumber(totalTokens))
            StatCard(label: "缓存 Token", value: Formatters.formatNumber(totalCachedInputTokens))
            StatCard(label: "活跃时长", value: Formatters.formatDuration(totalActiveSeconds), color: Color(red: 0.38, green: 0.6, blue: 1.0))
            StatCard(label: "总时长", value: Formatters.formatDuration(totalDurationSeconds))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    var color: Color = .white

    // Reserve fixed line-box heights so all cards render at exactly the same height,
    // even when minimumScaleFactor shrinks the value glyphs in narrower columns.
    private let labelHeight: CGFloat = 14   // 12pt font
    private let valueHeight: CGFloat = 24   // 20pt font

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.63))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(height: labelHeight, alignment: .leading)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: valueHeight, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 13)
        .background(Color(white: 0.09))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(white: 0.16), lineWidth: 1)
        )
    }
}
