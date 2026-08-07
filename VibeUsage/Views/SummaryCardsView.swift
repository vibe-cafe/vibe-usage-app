import SwiftUI

struct SummaryCardsView: View {
    @Environment(AppState.self) private var appState
    @State private var currencyMode: CurrencyMode = .usd
    @State private var totalTokenMode: TokenMode = .international
    @State private var cachedTokenMode: TokenMode = .international

    private enum CurrencyMode: Equatable {
        case usd
        case cny
    }

    private enum TokenMode: Equatable {
        case international
        case chinese
    }

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
        HStack(alignment: .top, spacing: 8) {
            StatCard(
                label: "预估费用",
                value: currencyMode == .usd ? Formatters.formatCost(totalCost) : Formatters.formatCnyCost(totalCost),
                color: Color(red: 0.2, green: 0.8, blue: 0.5),
                action: { currencyMode = currencyMode == .usd ? .cny : .usd },
                help: "点击切换美元/人民币；精确值：\(Formatters.formatCost(totalCost))"
            )
            StatCard(
                label: "总 Token",
                value: totalTokenMode == .international ? Formatters.formatNumber(totalTokens) : Formatters.formatChineseTokens(totalTokens),
                action: { totalTokenMode = totalTokenMode == .international ? .chinese : .international },
                help: "点击切换国际/中文单位；精确值：\(formatExactInteger(totalTokens))"
            )
            StatCard(
                label: "缓存 Token",
                value: cachedTokenMode == .international ? Formatters.formatNumber(totalCachedInputTokens) : Formatters.formatChineseTokens(totalCachedInputTokens),
                action: { cachedTokenMode = cachedTokenMode == .international ? .chinese : .international },
                help: "点击切换国际/中文单位；精确值：\(formatExactInteger(totalCachedInputTokens))"
            )
            StatCard(label: "活跃时长", value: Formatters.formatDuration(totalActiveSeconds), color: Color(red: 0.38, green: 0.6, blue: 1.0))
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.28), value: totalCost)
        .animation(.easeInOut(duration: 0.28), value: totalTokens)
        .animation(.easeInOut(duration: 0.28), value: totalCachedInputTokens)
        .animation(.easeInOut(duration: 0.28), value: totalActiveSeconds)
    }

    private func formatExactInteger(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    var color: Color = .white
    var action: (() -> Void)?
    var help: String?

    // Reserve fixed line-box heights so all cards render at exactly the same height,
    // even when minimumScaleFactor shrinks the value glyphs in narrower columns.
    private let labelHeight: CGFloat = 14   // 12pt font
    private let valueHeight: CGFloat = 24   // 20pt font

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    cardContent
                }
                .buttonStyle(.plain)
                .help(help ?? label)
                .accessibilityLabel(label)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.63))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
                .frame(height: labelHeight, alignment: .leading)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, minHeight: valueHeight, maxHeight: valueHeight, alignment: .leading)
                .clipped()
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
