import SwiftUI

/// Off-screen renders only: a fixed clock and the hover, menu and family
/// states a still image cannot reach with a pointer. The app leaves it empty.
struct RecentUsagePreview {
    var now: Date?
    var hoveredSlot: Int?
    var heroHovered = false
    var activityHovered = false
    var menu: UsageFilterMenuState.Submenu??
    var expandedFamilies: Set<String> = []
    /// View tests: what the card settled on after each update.
    var onShow: (@MainActor (RecentUsageShown) -> Void)?
}

/// What 近期消耗 drew, reported to view tests.
struct RecentUsageShown: Equatable {
    enum Kind: Equatable { case loading, unavailable, figures, faded }
    let kind: Kind
    let cost: Double?
}

extension EnvironmentValues {
    @Entry var recentUsagePreview = RecentUsagePreview()
}

/// Colors of the curve and the dark hover blocks (design §4, 134b, 134l).
enum RecentUsageStyle {
    /// The warm white of rings, ticks and curves: `rgb(237,233,225)`.
    static let ink = Color(red: 237 / 255, green: 233 / 255, blue: 225 / 255)
    static let blockTop = Color(settingsHex: 0x2A2E34)
    static let blockBottom = Color(settingsHex: 0x22262B)
    /// The hover ring's fill.
    static let markerFill = Color(settingsHex: 0x1B1E23)
}

/// The body of 近期消耗 with a linked account (134): the big number and two
/// small rows on the left, the curve on the right. Every figure comes from
/// `AppState.usageDisplaySnapshot` (#105) and `AppState.activity`.
///
/// What it shows follows the rule shared with the details cards
/// (`UsageFigures`, kept by `UsageFiguresKeeper`): the selected period's
/// successful read draws figures; while a new period loads, the previous
/// figures stay faded until that read ends (134r); a read that ended without
/// figures shows 「—」, never 0; an account or server change drops the kept
/// figures at once. The figures are worked out again only when the data,
/// the period, the effective filters, the read state or the account change,
/// or the panel opens again: hero, unit and hover changes reuse them.
struct ModernRecentUsageBody: View {
    @Environment(AppState.self) private var appState
    @Environment(\.recentUsagePreview) private var preview

    @State private var keeper = UsageFiguresKeeper()
    @State private var figures = UsageFigures.loading
    @State private var builtAt = Date()
    @State private var builtRange = TimeRange.today
    /// The slots of the activity curve (period, terminal and tool; never the model).
    @State private var activityGrid: UsagePlotGrid?
    /// The activity that goes with the figures on screen.
    @State private var activity: ActivityReport?

    private var filters: UsagePanelFilters {
        appState.modernPanel.usageFilters(appState.filters, enabled: appState.quotaCardProviders)
    }

    /// Every end of a read counts (`usageReadsFinished`), not the loading
    /// flag or the bucket count: a read that ends before the next update, or
    /// a refresh with as many buckets but other figures, must still redraw.
    private struct RebuildKey: Equatable {
        let filters: UsagePanelFilters
        let range: TimeRange
        let from: Date
        let to: Date
        let readsFinished: UInt
        let account: UInt
        let presentation: Int
    }

    private var rebuildKey: RebuildKey {
        RebuildKey(
            filters: filters, range: appState.timeRange,
            from: appState.customRangeFrom, to: appState.customRangeTo,
            readsFinished: appState.usageReadsFinished, account: appState.usageAccount,
            presentation: appState.modernPanel.presentation
        )
    }

    private var isFaded: Bool {
        if case .figures(_, faded: true) = figures { return true }
        return false
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: ModernTheme.recentUsageBodyHeight, alignment: .top)
            .onChange(of: rebuildKey, initial: true) { rebuild() }
            .onChange(of: appState.activity) { _, latest in
                if !isFaded { activity = latest }
            }
    }

    private func rebuild() {
        let now = preview.now ?? Date()
        figures = keeper.figures(appState, filters: filters, now: now)
        switch figures {
        case .figures(let snapshot, faded: false):
            builtAt = now
            builtRange = appState.timeRange
            activityGrid = filters.models.isEmpty && !snapshot.series.isEmpty
                ? snapshot.grid
                : appState.activityPlotGrid(filters: filters, now: now)
            activity = appState.activity
        case .figures(_, faded: true):
            break  // the previous period's activity and slots stay with its figures
        case .loading, .unavailable:
            activityGrid = nil
            activity = appState.activity
        }
        if let report = preview.onShow {
            switch figures {
            case .loading: report(RecentUsageShown(kind: .loading, cost: nil))
            case .unavailable: report(RecentUsageShown(kind: .unavailable, cost: nil))
            case .figures(let snapshot, let faded):
                report(RecentUsageShown(kind: faded ? .faded : .figures, cost: snapshot.total.cost))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let hero = appState.modernPanel.hero
        let units = appState.modernPanel.usage
        switch figures {
        case .loading:
            loading(hero)
        case .unavailable:
            // Nothing read for this period: 「—」, never zeros, and no curve.
            HStack(alignment: .top, spacing: 0) {
                RecentUsageNumbers(figures: RecentUsageFigures(total: nil, activity: activity?.summary, units: units),
                                   hero: hero, activity: activity, isEmpty: true)
                RecentUsageLoadingPlot(showsLabel: false)
            }
        case .figures(let snapshot, let faded):
            let isEmpty = RecentUsageChart.isEmpty(hero, snapshot: snapshot, activity: activity)
            let figures = RecentUsageFigures(total: snapshot.total, activity: activity?.summary, units: units)
            if isEmpty && faded {
                loading(hero)
            } else if isEmpty {
                // 134s
                HStack(alignment: .top, spacing: 0) {
                    RecentUsageNumbers(figures: figures, hero: hero, activity: activity, isEmpty: true)
                    emptyMessage
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    // 134r: the old figures fade while the new period loads.
                    RecentUsageNumbers(figures: figures, hero: hero, activity: activity, isEmpty: false,
                                       isInteractive: !faded)
                        .opacity(faded ? 0.38 : 1)
                        .zIndex(1)
                    RecentUsagePlot(chart: makeChart(snapshot, hero: hero, units: units), isFaded: faded,
                                    isLoading: faded, initialHover: preview.hoveredSlot)
                        .id(hero)
                }
            }
        }
    }

    /// 134q: gray blocks while the first figures are on their way.
    private func loading(_ hero: ChartMode) -> some View {
        HStack(alignment: .top, spacing: 0) {
            RecentUsageLoadingNumbers(hero: hero)
            RecentUsageLoadingPlot(showsLabel: true)
        }
    }

    /// The curve of the big number's metric. Active time is drawn over the
    /// slots of the usage it is filtered like (period, terminal and tool),
    /// so a model filter neither cuts its start nor hides it.
    private func makeChart(_ snapshot: UsageDisplaySnapshot, hero: ChartMode, units: UsagePanelState) -> RecentUsageChart {
        if hero == .activeTime {
            let grid = activityGrid ?? snapshot.grid
            return RecentUsageChart(activityGrid: grid, activity: RecentUsageChart.activity(activity, grid: grid),
                                    units: units, rolling: builtRange == .oneDay, now: builtAt)
        }
        return RecentUsageChart(snapshot: snapshot, metric: hero,
                                activity: RecentUsageChart.activity(activity, grid: snapshot.grid),
                                units: units, rolling: builtRange == .oneDay, now: builtAt)
    }

    /// 134s: 「暂无数据」 and the design's one line, which only fits when
    /// nothing narrows the figures (a filter or a subscription would make
    /// it wrong).
    private var emptyMessage: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("暂无数据")
                .font(ModernTheme.text(13, .medium))
                .foregroundStyle(ModernTheme.text)
                .frame(height: 18)
            if filters == UsagePanelFilters() {
                Text("用了 AI 编程工具以后，数据会自动同步到这里。")
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .lineLimit(2)
                    .frame(minHeight: 16, alignment: .topLeading)
            }
        }
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Numbers (left column)

/// The big number with its caption on top and the two other metrics below
/// (134a, 134l–134p). Clicking the big number switches its unit; clicking a
/// small row makes it the big number.
private struct RecentUsageNumbers: View {
    @Environment(AppState.self) private var appState
    @Environment(\.recentUsagePreview) private var preview
    let figures: RecentUsageFigures
    let hero: ChartMode
    let activity: ActivityReport?
    let isEmpty: Bool
    var isInteractive = true

    @State private var heroHovered = false
    @State private var activityHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                heroButton.zIndex(1)
                Text(RecentUsageFigures.label(hero))
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .frame(height: 18)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(RecentUsageFigures.rows(besides: hero), id: \.self) { metric in
                    row(metric).zIndex(metric == .activeTime ? 1 : 0)
                }
            }
        }
        .frame(width: ModernTheme.leadingColumnWidth, height: ModernTheme.recentUsageBodyHeight, alignment: .topLeading)
        .onAppear {
            heroHovered = preview.heroHovered
            activityHovered = preview.activityHovered
        }
    }

    private var heroButton: some View {
        Button {
            appState.modernPanel.usage.toggleHeroUnit()
        } label: {
            RecentUsageBigNumber(
                parts: RecentUsageNumber.parts(figures.text(hero), dropsCentsFromHundred: hero == .cost),
                isMuted: isEmpty
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive || hero == .activeTime && activity == nil)
        .onHover { inside in if isInteractive { heroHovered = inside } }
        .overlay(alignment: .topLeading) {
            if heroHovered, let lines = heroHoverLines {
                RecentUsageHoverBlock(primary: lines.primary, secondary: lines.secondary)
                    .fixedSize()
                    .offset(x: -2, y: 47)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("\(RecentUsageFigures.label(hero)) \(figures.text(hero))")
    }

    /// 134p: the exact figure and what a click does; for active time, the
    /// AI work time and average concurrency (or why it is missing).
    private var heroHoverLines: (primary: String?, secondary: String?)? {
        if hero == .activeTime {
            guard let help = activity?.summaryHelp(duration: RecentUsageNumber.duration), !help.isEmpty else { return nil }
            return (nil, help)
        }
        guard !isEmpty, let exact = figures.exactText(hero) else { return nil }
        return (exact, figures.unitHint(hero))
    }

    private func row(_ metric: ChartMode) -> some View {
        Button {
            appState.modernPanel.hero = metric
        } label: {
            RecentUsageRowLabel(title: RecentUsageFigures.rowLabel(metric), value: figures.text(metric),
                                isMuted: isEmpty)
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .overlay(alignment: .bottomLeading) {
            if metric == .activeTime, activityHovered,
               let help = activity?.summaryHelp(duration: RecentUsageNumber.duration), !help.isEmpty {
                RecentUsageHoverBlock(primary: nil, secondary: help)
                    .fixedSize()
                    .offset(x: -2, y: -22)
                    .allowsHitTesting(false)
            }
        }
        .onHover { inside in
            if metric == .activeTime, isInteractive { activityHovered = inside }
        }
    }
}

/// 「$41.20」 as drawn: the sign at 22 pt and 50 %, the integer at 44 pt,
/// the decimals and units at 22 pt and 62 %, JetBrains Mono Light. Muted
/// (134s) is all at 30 %.
private struct RecentUsageBigNumber: View {
    let parts: [RecentUsageNumberPart]
    var isMuted = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                piece(part, next: index + 1 < parts.count ? parts[index + 1] : nil)
            }
        }
        .foregroundStyle(isMuted ? ModernTheme.text.opacity(0.3) : ModernTheme.text)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        // CSS line-height 1: a 44 pt box with the baseline where the browser
        // puts it, not the font's taller natural line.
        .frame(height: 58)
        .padding(.vertical, -7)
    }

    @ViewBuilder
    private func piece(_ part: RecentUsageNumberPart, next: RecentUsageNumberPart?) -> some View {
        let small = ModernTheme.mono(22, .light)
        switch part.role {
        case .symbol:
            Text(part.text)
                .font(small)
                .foregroundStyle(isMuted ? ModernTheme.text.opacity(0.3) : ModernTheme.tertiaryText)
                .padding(.trailing, 1)
        case .integer:
            Text(part.text)
                .font(ModernTheme.mono(44, .light))
                .tracking(-2.64)
        case .fraction:
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(".").padding(.leading, -3).padding(.trailing, -4)
                Text(part.text).tracking(-1.1)
            }
            .font(small)
            .foregroundStyle(isMuted ? ModernTheme.text.opacity(0.3) : ModernTheme.secondaryText)
        case .unit:
            Text(part.text)
                .font(small)
                .foregroundStyle(isMuted ? ModernTheme.text.opacity(0.3) : ModernTheme.secondaryText)
                .padding(.leading, 2)
                .padding(.trailing, next?.role == .integer ? 7 : 0)
        }
    }
}

/// A small row: 11 pt label in a 36 pt column, the value at 13 pt.
private struct RecentUsageRowLabel: View {
    let title: String
    let value: String
    var isMuted = false
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(ModernTheme.text(11))
                .foregroundStyle(isHovered && isEnabled ? ModernTheme.text : ModernTheme.secondaryText)
                .frame(width: 36, alignment: .leading)
            RecentUsageWords(value, spacing: 4.5)
                .font(ModernTheme.mono(13, .medium))
                .foregroundStyle(isMuted ? ModernTheme.secondaryText : ModernTheme.text)
                .lineLimit(1)
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// Words set closer than the font's own space, like the design's negative
/// `word-spacing` on 「3h 12m」 and 「昨天 21:00」.
struct RecentUsageWords: View {
    let words: [String]
    let spacing: CGFloat

    init(_ text: String, spacing: CGFloat) {
        words = text.split(separator: " ").map(String.init)
        self.spacing = spacing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                Text(word)
            }
        }
    }
}

/// The dark block a hover shows over a number (134p): the exact figure,
/// then a note in the secondary color.
struct RecentUsageHoverBlock: View {
    let primary: String?
    let secondary: String?

    var body: some View {
        HStack(spacing: 10) {
            if let primary {
                Text(primary)
                    .font(ModernTheme.mono(11, .medium))
                    .foregroundStyle(ModernTheme.text)
            }
            if let secondary {
                Text(secondary)
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
            }
        }
        .frame(height: 16)
        .padding(.horizontal, 9)
        .padding(.top, 5)
        .padding(.bottom, 6)
        .background(RecentUsageBlockBackground(cornerRadius: 7))
    }
}

/// `linear-gradient(#2A2E34, #22262B)`, an 8 % top highlight, a soft drop
/// shadow and a 1 pt dark rim: the menus' and hover blocks' surface.
struct RecentUsageBlockBackground: View {
    var cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [RecentUsageStyle.blockTop, RecentUsageStyle.blockBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    .mask(alignment: .top) {
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: cornerRadius)
                    }
            }
            .shadow(color: .black.opacity(0.5), radius: 11, y: 8)
            .overlay { shape.inset(by: -1).strokeBorder(Color.black.opacity(0.45), lineWidth: 1) }
    }
}

// MARK: - Curve (right column)

/// The curve (134a–134d): the peak's label and a dashed line at the top, the
/// filled curve with its end dot, two ticks, and the axis labels below. The
/// pointer snaps to a slot and shows its figures (134b, 134c, 134l).
private struct RecentUsagePlot: View {
    let chart: RecentUsageChart
    var isFaded = false
    var isLoading = false
    var initialHover: Int?

    @State private var hovered: Int?
    private let height: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    // 134r: only the old curve stays, faded, under 「加载中」.
                    RecentUsageCurve(chart: chart)
                        .opacity(isFaded ? 0.3 : 1)
                    if !isFaded, chart.hasKnownPoints {
                        peakLine
                        ForEach(Array(chart.ticks.enumerated()), id: \.offset) { _, tick in
                            Rectangle()
                                .fill(ModernTheme.text.opacity(0.2))
                                .frame(width: 1, height: 4)
                                .offset(x: (tick.x * width).rounded(), y: height - 4)
                        }
                    }
                    if !isFaded, let hovered, hovered < chart.hoverPoints.count {
                        marker(hovered, width: width)
                    }
                    if isLoading {
                        RecentUsageLoadingLabel()
                            .frame(width: width, height: height)
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard !isFaded else { return }
                    switch phase {
                    case .active(let location):
                        hovered = nearest(location.x / max(1, width))
                    case .ended:
                        hovered = nil
                    }
                }
            }
            .frame(height: height)
            axis.opacity(isFaded ? 0.3 : 1)
        }
        .frame(maxWidth: .infinity)
        .onAppear { hovered = initialHover }
    }

    private func nearest(_ x: Double) -> Int? {
        chart.hoverPoints.indices.min { abs(chart.hoverPoints[$0].x - x) < abs(chart.hoverPoints[$1].x - x) }
    }

    /// The peak's label at the top left and a dashed line from it to the
    /// right edge at the peak's height.
    private var peakLine: some View {
        HStack(spacing: 7) {
            Text(chart.peakLabel)
                .font(ModernTheme.mono(11))
                .foregroundStyle(ModernTheme.secondaryText)
                .frame(height: 12)
                .fixedSize()
            Line()
                .stroke(ModernTheme.text.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
        }
        .padding(.top, 2)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }

    /// 9:00 … 11:00 … 13:00 … 现在.
    private var axis: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RecentUsageWords(chart.startLabel, spacing: 4.4)
                    .font(ModernTheme.mono(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array((isFaded ? [] : chart.ticks).enumerated()), id: \.offset) { _, tick in
                    Text(tick.label)
                        .font(ModernTheme.mono(11))
                        .foregroundStyle(ModernTheme.secondaryText)
                        .fixedSize()
                        .frame(width: 80)
                        .offset(x: tick.x * proxy.size.width - 40)
                }
                // 「现在」 and 「今天」 stand out; a past last day reads like the others.
                let isPresent = chart.endLabel.first?.isNumber != true
                Text(chart.endLabel)
                    .font(isPresent ? ModernTheme.text(11, .medium) : ModernTheme.mono(11))
                    .foregroundStyle(isPresent ? ModernTheme.text : ModernTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 18)
            .lineLimit(1)
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private func marker(_ index: Int, width: CGFloat) -> some View {
        let point = chart.hoverPoints[index]
        let x = point.x * width
        let y = RecentUsageCurve.y(point.value, peak: chart.peak, height: height)
        // An unknown slot has no point on the curve: only its 「—」.
        if point.isKnown {
            Rectangle()
                .fill(ModernTheme.text.opacity(0.3))
                .frame(width: 1, height: max(0, height - y))
                .offset(x: x - 0.5, y: y)
            Circle()
                .fill(RecentUsageStyle.markerFill)
                .overlay(Circle().strokeBorder(RecentUsageStyle.ink, lineWidth: 1.5))
                .frame(width: 8, height: 8)
                .offset(x: x - 4, y: y - 4)
        }
        if index < chart.tooltips.count {
            RecentUsageTooltipView(tooltip: chart.tooltips[index], pointX: x, pointY: y, width: width)
        }
    }
}

/// The filled curve: a monotone cubic through the slot points (it never
/// overshoots below zero or above the peak), a gradient under it, a 1.5 pt
/// stroke, the baseline and the end dot.
private struct RecentUsageCurve: View {
    let chart: RecentUsageChart

    static func y(_ value: Double, peak: Double, height: CGFloat) -> CGFloat {
        guard peak > 0 else { return height - 1.5 }
        return height - 1.5 - CGFloat(value / peak) * (height - 10)
    }

    var body: some View {
        Canvas { context, size in
            let points = chart.curve.map {
                CGPoint(x: $0.x * size.width, y: Self.y($0.value, peak: chart.peak, height: size.height))
            }
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(RecentUsageStyle.ink.opacity(0.14)), lineWidth: 1)
            guard let first = points.first, let last = points.last else { return }

            let line = Self.monotonePath(points)
            var fill = line
            fill.addLine(to: CGPoint(x: last.x, y: size.height))
            fill.addLine(to: CGPoint(x: first.x, y: size.height))
            fill.closeSubpath()
            let top = points.map(\.y).min() ?? 0
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [RecentUsageStyle.ink.opacity(0.28), RecentUsageStyle.ink.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(RecentUsageStyle.ink.opacity(0.92)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let dot = CGRect(x: size.width - 3.5 - 3, y: max(4, last.y) - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot), with: .color(RecentUsageStyle.ink))
        }
    }

    /// Fritsch–Carlson monotone cubic (the design's `pchip`) as Bézier segments.
    static func monotonePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        let count = points.count
        var slopes = [CGFloat](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            slopes[index] = dx == 0 ? 0 : (points[index + 1].y - points[index].y) / dx
        }
        var tangents = [CGFloat](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        for index in 1..<(count - 1) {
            let left = slopes[index - 1], right = slopes[index]
            if left * right <= 0 {
                tangents[index] = 0
            } else {
                let h0 = points[index].x - points[index - 1].x
                let h1 = points[index + 1].x - points[index].x
                let w0 = 2 * h1 + h0, w1 = h1 + 2 * h0
                tangents[index] = (w0 + w1) / (w0 / left + w1 / right)
            }
        }
        for index in 0..<(count - 1) {
            let p0 = points[index], p1 = points[index + 1]
            let h = (p1.x - p0.x) / 3
            path.addCurve(to: p1,
                          control1: CGPoint(x: p0.x + h, y: p0.y + tangents[index] * h),
                          control2: CGPoint(x: p1.x - h, y: p1.y - tangents[index + 1] * h))
        }
        return path
    }
}

/// The hover content over the curve: a one-line pill centered above the
/// point (134b, 134c), or a small table beside it (134l).
private struct RecentUsageTooltipView: View {
    let tooltip: RecentUsageTooltip
    let pointX: CGFloat
    let pointY: CGFloat
    let width: CGFloat
    @State private var size: CGSize = .zero

    var body: some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(origin)
            .allowsHitTesting(false)
    }

    private var origin: CGSize {
        switch tooltip {
        case .line:
            let x = min(max(pointX - size.width / 2, -12), width - size.width)
            var y = pointY - 10 - size.height
            if y < -6 { y = pointY + 10 }
            return CGSize(width: x, height: y)
        case .table:
            let x = pointX > width / 2 ? pointX - 14 - size.width : pointX + 14
            return CGSize(width: x, height: -4)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tooltip {
        case .line(let period, let value):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RecentUsageWords(period, spacing: 4.4)
                    .font(ModernTheme.mono(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                Text(value)
                    .font(ModernTheme.mono(11, .medium))
                    .foregroundStyle(ModernTheme.text)
            }
            .frame(height: 22)
            .padding(.horizontal, 8)
            .background(RecentUsageBlockBackground(cornerRadius: 6))
        case .table(let period, let rows):
            VStack(alignment: .leading, spacing: 2) {
                Text(period)
                    .font(ModernTheme.mono(11, .medium))
                    .foregroundStyle(ModernTheme.text)
                    .frame(height: 16)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.label)
                                .font(ModernTheme.text(11))
                                .foregroundStyle(ModernTheme.secondaryText)
                            Text(row.value)
                                .font(ModernTheme.mono(11))
                                .foregroundStyle(ModernTheme.text)
                                .gridColumnAlignment(.trailing)
                        }
                        .frame(height: 16)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 8)
            .background(RecentUsageBlockBackground(cornerRadius: 8))
        }
    }
}

// MARK: - Loading (134q, 134r)

/// The spinner and 「加载中」, centered on the curve.
private struct RecentUsageLoadingLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            ModernSpinner(size: 12)
            Text("加载中")
                .font(ModernTheme.text(11))
                .foregroundStyle(ModernTheme.secondaryText)
        }
    }
}

/// 134q: gray blocks where the numbers will be.
private struct RecentUsageLoadingNumbers: View {
    let hero: ChartMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ModernTheme.placeholder)
                    .frame(width: 108, height: 32)
                    .padding(.bottom, 5)
                    .frame(height: 44, alignment: .bottom)
                Text(RecentUsageFigures.label(hero))
                    .font(ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .frame(height: 18)
            }
            Spacer(minLength: 0)
            ForEach(Array(RecentUsageFigures.rows(besides: hero).enumerated()), id: \.offset) { index, metric in
                HStack(spacing: 10) {
                    Text(RecentUsageFigures.rowLabel(metric))
                        .font(ModernTheme.text(11))
                        .foregroundStyle(ModernTheme.secondaryText)
                        .frame(width: 36, alignment: .leading)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(ModernTheme.placeholder)
                        .frame(width: index == 0 ? 50 : 42, height: 10)
                }
                .frame(height: 18)
            }
        }
        .frame(width: ModernTheme.leadingColumnWidth, height: ModernTheme.recentUsageBodyHeight, alignment: .topLeading)
    }
}

/// 134q: the baseline and 「加载中」 where the curve will be; after a read
/// that brought nothing, only the baseline.
private struct RecentUsageLoadingPlot: View {
    let showsLabel: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(ModernTheme.text.opacity(0.08))
                    .frame(height: 1)
                if showsLabel {
                    RecentUsageLoadingLabel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96, alignment: .bottom)
            Color.clear.frame(height: 18)
        }
        .frame(maxWidth: .infinity)
    }
}
