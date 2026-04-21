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
        HStack(spacing: 8) {
            StatCard(label: "预估费用", value: Formatters.formatCost(totalCost), color: Color(red: 0.2, green: 0.8, blue: 0.5))
            StatCard(label: "总 Token", value: Formatters.formatNumber(totalTokens))
            StatCard(label: "缓存 Token", value: Formatters.formatNumber(totalCachedInputTokens))
            StatCard(label: "活跃时长", value: Formatters.formatDuration(totalActiveSeconds), color: Color(red: 0.38, green: 0.6, blue: 1.0))
            StatCard(label: "总时长", value: Formatters.formatDuration(totalDurationSeconds))
        }
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    var color: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.63))
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color(white: 0.09))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(white: 0.16), lineWidth: 1)
        )
    }
}
