import SwiftUI

struct BarChartView: View {
    @Environment(AppState.self) private var appState
    @State private var hoveredBar: String?

    private struct BarData: Identifiable {
        let id: String // dayKey or hourKey
        var input: Int = 0
        var output: Int = 0
        var total: Int { input + output }
        var cost: Double = 0
    }

    private var isHourly: Bool {
        appState.timeRange == .oneDay
    }

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

    private var chartData: [BarData] {
        // Aggregate by hour or day
        var buckets: [String: BarData] = [:]
        for bucket in filtered {
            let key = isHourly ? bucket.hourKey : bucket.dayKey
            if buckets[key] == nil {
                buckets[key] = BarData(id: key)
            }
            buckets[key]!.input += bucket.inputTokens
            buckets[key]!.output += bucket.outputTokens
            buckets[key]!.cost += bucket.estimatedCost ?? 0
        }

        if isHourly {
            // Generate 24 hourly slots ending at current hour
            let calendar = Calendar.current
            let now = Date()
            let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            var result: [BarData] = []
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]

            for i in stride(from: 23, through: 0, by: -1) {
                if let hour = calendar.date(byAdding: .hour, value: -i, to: currentHour) {
                    // Format to yyyy-MM-ddTHH
                    let iso = isoFormatter.string(from: hour)
                    let key = String(iso.prefix(13))
                    result.append(buckets[key] ?? BarData(id: key))
                }
            }
            return result
        } else {
            // Fill in all days in range
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let numDays = appState.timeRange.days
            var result: [BarData] = []

            for i in stride(from: numDays - 1, through: 0, by: -1) {
                if let date = calendar.date(byAdding: .day, value: -i, to: today) {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    let key = formatter.string(from: date)
                    result.append(buckets[key] ?? BarData(id: key))
                }
            }
            return result
        }
    }

    private var maxTotal: Int {
        max(chartData.map(\.total).max() ?? 0, 1)
    }

    private var labelInterval: Int {
        let count = chartData.count
        if isHourly {
            if count <= 12 { return 2 }
            return 4 // Show every 4 hours
        }
        if count <= 3 { return 1 }
        if count <= 7 { return 2 }
        if count <= 15 { return 3 }
        return 7
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isHourly ? "每小时趋势" : "每日趋势")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(white: 0.63))
                Spacer()
                HStack(spacing: 12) {
                    legendItem(color: Color(white: 0.5), label: "输入")
                    legendItem(color: Color.white.opacity(0.9), label: "输出")
                }
            }
            .padding(.bottom, 12)

            // Chart
            HStack(alignment: .bottom, spacing: 0) {
                // Y-axis
                VStack {
                    Text(Formatters.formatNumber(maxTotal))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(white: 0.38))
                    Spacer()
                    Text("0")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(white: 0.38))
                }
                .frame(width: 40)
                .frame(height: 200)

                // Bars
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(chartData) { bar in
                        let inputH = CGFloat(bar.input) / CGFloat(maxTotal) * 200
                        let outputH = CGFloat(bar.output) / CGFloat(maxTotal) * 200

                        VStack(spacing: 0) {
                            // Output (top, white)
                            Rectangle()
                                .fill(Color.white.opacity(0.9))
                                .frame(height: outputH)
                                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                            // Input (bottom, zinc)
                            Rectangle()
                                .fill(Color(white: 0.5))
                                .frame(height: inputH)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 200, alignment: .bottom)
                        .onHover { hovering in
                            hoveredBar = hovering ? bar.id : nil
                        }
                    }
                }
                .overlay {
                    GeometryReader { geo in
                        if let hoveredId = hoveredBar,
                           let bar = chartData.first(where: { $0.id == hoveredId }),
                           let idx = chartData.firstIndex(where: { $0.id == hoveredId }) {
                            let barW = geo.size.width / CGFloat(chartData.count)
                            let cx = barW * (CGFloat(idx) + 0.5)
                            let clampedX = min(max(cx, 80), geo.size.width - 80)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(isHourly ? Formatters.formatHourShort(bar.id) : Formatters.formatDateShort(bar.id))
                                    .foregroundStyle(.white)
                                    .fontWeight(.medium)
                                Text("总 Token: \(Formatters.formatNumber(bar.total))")
                                    .foregroundStyle(Color(white: 0.8))
                                HStack(spacing: 8) {
                                    Text("输入: \(Formatters.formatNumber(bar.input))")
                                        .foregroundStyle(Color(white: 0.5))
                                    Text("输出: \(Formatters.formatNumber(bar.output))")
                                        .foregroundStyle(Color(white: 0.5))
                                }
                                Text("费用: \(Formatters.formatCost(bar.cost))")
                                    .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.5))
                            }
                            .font(.system(size: 10))
                            .padding(8)
                            .background(Color.black)
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.2), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                            .fixedSize()
                            .position(x: clampedX, y: 40)
                            .allowsHitTesting(false)
                        }
                    }
                }
            }

            // X-axis
            HStack(spacing: 1) {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 40)
                ForEach(Array(chartData.enumerated()), id: \.element.id) { index, bar in
                    Group {
                        if index % labelInterval == 0 {
                            Text(isHourly ? Formatters.formatHourShort(bar.id) : Formatters.formatDateShort(bar.id))
                                .font(.system(size: 9))
                                .foregroundStyle(Color(white: 0.5))
                                .lineLimit(1)
                                .fixedSize()
                        } else {
                            Text("")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(Color(white: 0.09))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(white: 0.16), lineWidth: 1)
        )
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.5))
        }
    }
}
