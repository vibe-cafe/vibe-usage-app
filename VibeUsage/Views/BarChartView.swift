import SwiftUI

struct BarChartView: View {
    @Environment(AppState.self) private var appState
    @State private var hoveredDay: String?

    private struct DayData: Identifiable {
        let id: String // dayKey
        var input: Int = 0
        var output: Int = 0
        var total: Int { input + output }
        var cost: Double = 0
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

    private var dailyData: [DayData] {
        // Aggregate by day
        var days: [String: DayData] = [:]
        for bucket in filtered {
            let key = bucket.dayKey
            if days[key] == nil {
                days[key] = DayData(id: key)
            }
            days[key]!.input += bucket.inputTokens
            days[key]!.output += bucket.outputTokens
            days[key]!.cost += bucket.estimatedCost ?? 0
        }

        // Fill in all days in range
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let numDays = appState.timeRange.days
        var result: [DayData] = []

        for i in stride(from: numDays - 1, through: 0, by: -1) {
            if let date = calendar.date(byAdding: .day, value: -i, to: today) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let key = formatter.string(from: date)
                result.append(days[key] ?? DayData(id: key))
            }
        }

        return result
    }

    private var maxTotal: Int {
        max(dailyData.map(\.total).max() ?? 0, 1)
    }

    private var labelInterval: Int {
        let count = dailyData.count
        if count <= 3 { return 1 }
        if count <= 7 { return 2 }
        if count <= 15 { return 3 }
        return 7
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("每日趋势")
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
                    ForEach(dailyData) { day in
                        let inputH = CGFloat(day.input) / CGFloat(maxTotal) * 200
                        let outputH = CGFloat(day.output) / CGFloat(maxTotal) * 200

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
                            hoveredDay = hovering ? day.id : nil
                        }
                    }
                }
                .overlay {
                    GeometryReader { geo in
                        if let hoveredId = hoveredDay,
                           let day = dailyData.first(where: { $0.id == hoveredId }),
                           let idx = dailyData.firstIndex(where: { $0.id == hoveredId }) {
                            let barW = geo.size.width / CGFloat(dailyData.count)
                            let cx = barW * (CGFloat(idx) + 0.5)
                            let clampedX = min(max(cx, 80), geo.size.width - 80)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(Formatters.formatDateShort(day.id))
                                    .foregroundStyle(.white)
                                    .fontWeight(.medium)
                                Text("总 Token: \(Formatters.formatNumber(day.total))")
                                    .foregroundStyle(Color(white: 0.8))
                                HStack(spacing: 8) {
                                    Text("输入: \(Formatters.formatNumber(day.input))")
                                        .foregroundStyle(Color(white: 0.5))
                                    Text("输出: \(Formatters.formatNumber(day.output))")
                                        .foregroundStyle(Color(white: 0.5))
                                }
                                Text("费用: \(Formatters.formatCost(day.cost))")
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
                ForEach(Array(dailyData.enumerated()), id: \.element.id) { index, day in
                    Group {
                        if index % labelInterval == 0 {
                            Text(Formatters.formatDateShort(day.id))
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
