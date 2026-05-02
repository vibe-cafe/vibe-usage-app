import SwiftUI

struct DistributionChartsView: View {
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

    var body: some View {
        let data = filtered
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 10) {
            DonutCardView(
                title: "终端分布",
                icon: "desktopcomputer",
                slices: aggregate(data, by: \.hostname)
            )
            DonutCardView(
                title: "工具分布",
                icon: "terminal",
                slices: aggregate(data, by: \.source)
            )
            DonutCardView(
                title: "模型分布",
                icon: "cpu",
                slices: aggregate(data, by: \.model)
            )
            DonutCardView(
                title: "项目分布",
                icon: "folder",
                slices: aggregate(data, by: \.project)
            )
        }
    }

    private func aggregate(_ buckets: [UsageBucket], by keyPath: KeyPath<UsageBucket, String>) -> [SliceData] {
        var map: [String: (tokens: Int, cost: Double)] = [:]
        for b in buckets {
            let key = b[keyPath: keyPath].isEmpty ? "未知" : b[keyPath: keyPath]
            let existing = map[key] ?? (tokens: 0, cost: 0)
            map[key] = (
                tokens: existing.tokens + b.computedTotal,
                cost: existing.cost + (b.estimatedCost ?? 0)
            )
        }

        let sorted = map.sorted { $0.value.tokens > $1.value.tokens }
        let colors: [Color] = [
            Color(red: 0.23, green: 0.51, blue: 0.96),
            Color(red: 0.06, green: 0.73, blue: 0.51),
            Color(red: 0.96, green: 0.62, blue: 0.04),
            Color(red: 0.94, green: 0.27, blue: 0.27),
            Color(red: 0.55, green: 0.36, blue: 0.96),
            Color(red: 0.93, green: 0.30, blue: 0.60),
        ]
        let otherColor = Color(white: 0.32)

        var slices: [SliceData] = []
        var otherTokens = 0
        var otherCost = 0.0

        for (i, entry) in sorted.enumerated() {
            if i < 6 {
                slices.append(SliceData(
                    label: entry.key,
                    tokens: entry.value.tokens,
                    cost: entry.value.cost,
                    color: colors[i % colors.count]
                ))
            } else {
                otherTokens += entry.value.tokens
                otherCost += entry.value.cost
            }
        }

        if otherTokens > 0 {
            slices.append(SliceData(label: "其他", tokens: otherTokens, cost: otherCost, color: otherColor))
        }

        return slices
    }
}

// MARK: - Data

struct SliceData: Identifiable {
    let id = UUID()
    let label: String
    let tokens: Int
    let cost: Double
    let color: Color
}

enum MetricMode {
    case tokens, cost

    var label: String {
        switch self {
        case .tokens: "Token"
        case .cost: "费用"
        }
    }
}

// MARK: - Donut Card

private struct DonutCardView: View {
    let title: String
    let icon: String
    let slices: [SliceData]
    @State private var mode: MetricMode = .tokens

    private var total: Double {
        switch mode {
        case .tokens: Double(slices.reduce(0) { $0 + $1.tokens })
        case .cost: slices.reduce(0) { $0 + $1.cost }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.5))
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(white: 0.63))
                }
                Spacer()
                MetricToggleView(mode: $mode)
            }

            if slices.isEmpty || total == 0 {
                Text("暂无数据")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.38))
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
            } else {
                VStack(spacing: 12) {
                    DonutShape(slices: slices, mode: mode, total: total)
                        .frame(width: 90, height: 90)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(slices) { slice in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(slice.color)
                                    .frame(width: 7, height: 7)
                                Text(slice.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(white: 0.7))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(valueText(slice))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.55))
                                Text(percentage(slice))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.38))
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.09))
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.16), lineWidth: 1))
    }

    private func valueText(_ slice: SliceData) -> String {
        switch mode {
        case .tokens: Formatters.formatNumber(slice.tokens)
        case .cost: Formatters.formatCost(slice.cost)
        }
    }

    private func percentage(_ slice: SliceData) -> String {
        guard total > 0 else { return "0%" }
        let value: Double = mode == .tokens ? Double(slice.tokens) : slice.cost
        let pct = value / total * 100
        if pct < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", pct)
    }
}

// MARK: - Metric Toggle

private struct MetricToggleView: View {
    @Binding var mode: MetricMode

    var body: some View {
        HStack(spacing: 2) {
            toggleButton(.tokens)
            toggleButton(.cost)
        }
        .padding(2)
        .background(Color(white: 0.16))
        .clipShape(Capsule())
    }

    private func toggleButton(_ m: MetricMode) -> some View {
        Button {
            mode = m
        } label: {
            Text(m.label)
                .font(.system(size: 11, weight: mode == m ? .medium : .regular))
                .foregroundStyle(mode == m ? .white : Color(white: 0.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(mode == m ? Color(white: 0.28) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Donut Shape

private struct DonutShape: View {
    let slices: [SliceData]
    let mode: MetricMode
    let total: Double

    private let lineWidth: CGFloat = 11

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(white: 0.16), lineWidth: lineWidth)

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - lineWidth / 2
                var startAngle = Angle.degrees(-90)

                for slice in slices {
                    let value: Double = mode == .tokens ? Double(slice.tokens) : slice.cost
                    let fraction = total > 0 ? value / total : 0
                    let sweep = Angle.degrees(fraction * 360)
                    let endAngle = startAngle + sweep

                    var path = Path()
                    path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)

                    context.stroke(path, with: .color(slice.color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))

                    startAngle = endAngle
                }
            }

            VStack(spacing: 1) {
                Text(mode == .tokens ? "Tokens" : "预估")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.45))
                Text(centerLabel)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    private var centerLabel: String {
        switch mode {
        case .tokens:
            let t = Int(total)
            if t >= 1_000_000_000 { return String(format: "%.1fB", Double(t) / 1_000_000_000) }
            if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
            if t >= 1_000 { return String(format: "%.1fK", Double(t) / 1_000) }
            return "\(t)"
        case .cost:
            return Formatters.formatCost(total)
        }
    }
}
