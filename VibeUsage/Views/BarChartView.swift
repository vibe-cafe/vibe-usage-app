import SwiftUI
import AppKit

/// Tracks whether the user is mid-scroll anywhere in the app.
///
/// SwiftUI's `.onHover`/`.onContinuousHover` keep firing while a `ScrollView`
/// scrolls, because the content slides under the (stationary) cursor. Every
/// fire mutates hover state and re-renders the chart, which competes with the
/// scroll animation on the main thread and makes the popover scroll stutter /
/// feel stuck whenever the pointer is over the 趋势 chart. We watch raw
/// `.scrollWheel` events and expose an `isScrolling` flag (debounced so trackpad
/// momentum doesn't flicker it) the chart uses to suspend hover during a scroll.
@MainActor
@Observable
private final class ScrollWatcher {
    private(set) var isScrolling = false
    private var monitor: Any?
    private var resetTask: Task<Void, Never>?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            Task { @MainActor in self?.bump() }
            return event // never consume — the ScrollView still needs it
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        resetTask?.cancel()
        resetTask = nil
        isScrolling = false
    }

    private func bump() {
        if !isScrolling { isScrolling = true } // set once per gesture (avoid notify storm)
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            self?.isScrolling = false
        }
    }
}

private struct BarData: Identifiable {
    let id: String // dayKey or hourKey
    var input: Int = 0
    var output: Int = 0
    var total: Int { input + output }
    var cost: Double = 0
    var activeMinutes: Double = 0
}

struct BarChartView: View {
    @Environment(AppState.self) private var appState

    private var isHourly: Bool {
        appState.timeRange.isHourly
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

        for session in appState.filteredSessions {
            let key = isHourly ? session.hourKey : session.dayKey
            if buckets[key] == nil {
                buckets[key] = BarData(id: key)
            }
            buckets[key]!.activeMinutes += Double(session.activeSeconds) / 60.0
        }

        if isHourly {
            // Generate hourly slots. For `.today` we start at local midnight
            // (slot count grows through the day, 1→24); for `.oneDay` we keep
            // the 24-slot rolling window ending at the current hour.
            let calendar = Calendar.current
            let now = Date()
            let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            let start: Date = {
                if appState.timeRange == .today {
                    return calendar.startOfDay(for: now)
                }
                return calendar.date(byAdding: .hour, value: -23, to: currentHour) ?? currentHour
            }()
            var result: [BarData] = []
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]

            var hour = start
            while hour <= currentHour {
                let iso = isoFormatter.string(from: hour)
                let key = String(iso.prefix(13))
                result.append(buckets[key] ?? BarData(id: key))
                guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
                hour = next
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

    private var maxCost: Double {
        max(chartData.map(\.cost).max() ?? 0, 0.001)
    }

    private var maxActiveMinutes: Double {
        max(chartData.map(\.activeMinutes).max() ?? 0, 0.1)
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
        @Bindable var state = appState

        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isHourly ? "每小时趋势" : "每日趋势")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(white: 0.63))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(ChartMode.allCases, id: \.self) { mode in
                        Button(action: { state.chartMode = mode }) {
                            Text(mode.rawValue)
                                .font(.system(size: 11, weight: state.chartMode == mode ? .medium : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(state.chartMode == mode ? Color(white: 0.28) : Color.clear)
                                .foregroundStyle(state.chartMode == mode ? Color.white : Color(white: 0.5))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color(white: 0.16))
                .clipShape(Capsule())
            }
            .padding(.bottom, 14)

            // The bars/tooltip/x-axis live in a child view that owns the hover
            // state. The expensive `chartData` aggregation is computed here in
            // the parent and passed down, so a hover change only re-renders the
            // lightweight child — it never re-runs the O(n) aggregation. This,
            // plus the single hover region inside ChartContent, keeps the
            // popover ScrollView smooth when the cursor passes over the chart.
            ChartContent(
                data: chartData,
                chartMode: state.chartMode,
                isHourly: isHourly,
                maxTotal: maxTotal,
                maxCost: maxCost,
                maxActiveMinutes: maxActiveMinutes,
                labelInterval: labelInterval
            )
        }
        .padding(14)
        .background(Color(white: 0.09))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(white: 0.16), lineWidth: 1)
        )
    }

}

private struct ChartContent: View {
    let data: [BarData]
    let chartMode: ChartMode
    let isHourly: Bool
    let maxTotal: Int
    let maxCost: Double
    let maxActiveMinutes: Double
    let labelInterval: Int

    @State private var hoveredIndex: Int?
    @State private var scroll = ScrollWatcher()

    var body: some View {
        VStack(spacing: 0) {
            // Chart
            HStack(alignment: .bottom, spacing: 6) {
                // Y-axis
                VStack(alignment: .trailing) {
                    Group {
                        switch chartMode {
                        case .token:
                            Text(Formatters.formatNumber(maxTotal))
                        case .cost:
                            Text(Formatters.formatCost(maxCost))
                        case .activeTime:
                            Text(Formatters.formatDuration(Int(maxActiveMinutes * 60)))
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.38))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    Spacer()
                    Text("0")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(white: 0.38))
                        .lineLimit(1)
                }
                .frame(width: 44)
                .frame(height: 150)

                // Bars
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(data) { bar in
                        VStack(spacing: 0) {
                            switch chartMode {
                            case .token:
                                let inputH = CGFloat(bar.input) / CGFloat(maxTotal) * 150
                                let outputH = CGFloat(bar.output) / CGFloat(maxTotal) * 150
                                // Output (top, white)
                                Rectangle()
                                    .fill(Color.white.opacity(0.9))
                                    .frame(height: outputH)
                                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                                // Input (bottom, zinc)
                                Rectangle()
                                    .fill(Color(white: 0.5))
                                    .frame(height: inputH)
                            case .cost:
                                let costH = CGFloat(bar.cost) / CGFloat(maxCost) * 150
                                Rectangle()
                                    .fill(Color(red: 0.2, green: 0.8, blue: 0.5))
                                    .frame(height: costH)
                                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                            case .activeTime:
                                let activeH = CGFloat(bar.activeMinutes) / CGFloat(maxActiveMinutes) * 150
                                Rectangle()
                                    .fill(Color(red: 0.38, green: 0.6, blue: 1.0))
                                    .frame(height: activeH)
                                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 150, alignment: .bottom)
                    }
                }
                .overlay {
                    GeometryReader { geo in
                        // ONE hover tracking area for the whole bar strip
                        // (replaces the former per-bar .onHover — 24–90
                        // NSTrackingAreas). While the popover is being
                        // scrolled we drop hit-testing entirely so the wheel
                        // events flow straight to the ScrollView and no hover
                        // fires; that, plus the .active guard below, keeps the
                        // chart subtree static during a scroll so it no longer
                        // stutters / sticks.
                        Color.clear
                            .contentShape(Rectangle())
                            .allowsHitTesting(!scroll.isScrolling)
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                switch phase {
                                case .active(let p):
                                    guard !scroll.isScrolling,
                                          !data.isEmpty, geo.size.width > 0 else { return }
                                    let barW = geo.size.width / CGFloat(data.count)
                                    let idx = min(max(Int(p.x / barW), 0), data.count - 1)
                                    if hoveredIndex != idx { hoveredIndex = idx }
                                case .ended:
                                    if hoveredIndex != nil { hoveredIndex = nil }
                                }
                            }

                        if let idx = hoveredIndex, data.indices.contains(idx) {
                            let bar = data[idx]
                            let barW = geo.size.width / CGFloat(data.count)
                            let cx = barW * (CGFloat(idx) + 0.5)
                            let clampedX = min(max(cx, 80), geo.size.width - 80)

                            tooltip(for: bar)
                                .position(x: clampedX, y: 40)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }

            // X-axis
            HStack(spacing: 2) {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 44)
                Rectangle()
                    .fill(.clear)
                    .frame(width: 6)
                ForEach(Array(data.enumerated()), id: \.element.id) { index, bar in
                    Group {
                        if index % labelInterval == 0 {
                            Text(isHourly ? Formatters.formatHourShort(bar.id) : Formatters.formatDateShort(bar.id))
                                .font(.system(size: 11))
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
            .padding(.top, 8)
        }
        .onAppear { scroll.start() }
        .onDisappear { scroll.stop() }
        .onChange(of: scroll.isScrolling) { _, scrolling in
            // Hide the tooltip as soon as a scroll starts so it doesn't hang
            // frozen over the moving content until the gesture ends.
            if scrolling, hoveredIndex != nil { hoveredIndex = nil }
        }
    }

    @ViewBuilder
    private func tooltip(for bar: BarData) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isHourly ? Formatters.formatHourShort(bar.id) : Formatters.formatDateShort(bar.id))
                .foregroundStyle(.white)
                .fontWeight(.medium)

            switch chartMode {
            case .token:
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
            case .cost:
                Text("费用: \(Formatters.formatCost(bar.cost))")
                    .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.5))
            case .activeTime:
                Text("活跃时长: \(Formatters.formatDuration(Int(bar.activeMinutes * 60)))")
                    .foregroundStyle(Color(red: 0.38, green: 0.6, blue: 1.0))
            }
        }
        .font(.system(size: 11))
        .padding(8)
        .background(Color.black)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
        .fixedSize()
    }
}
