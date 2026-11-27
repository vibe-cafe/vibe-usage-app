import AppKit
import SwiftUI

// MARK: - Section (135)

/// The four cards 展开详情 adds under the two cards above, whose look never
/// changes (135a): 模型分布 and Token 构成, then 终端分布 and 工具分布,
/// 244 × 252 each. They count what 近期消耗 counts — its period, the filters
/// and the selected subscription (135b) — and each distribution card has its
/// own Token / 费用 switch (135c). Rankings, shares, rank colors and the Token
/// composition come from `UsageDisplaySnapshot`; the cards only draw them.
struct ModernDetailsSection: View {
    @Environment(AppState.self) private var appState
    /// Off-screen renders only: the card whose 「其余 N 个」 list starts open.
    var openRemainder: UsageRanking.Dimension?
    @State private var memory = SnapshotMemory()

    var body: some View {
        // Reads only what the figures depend on: switching a card's metric or
        // opening a list redraws the grid without rebuilding the snapshot.
        let filters = appState.modernPanel.usageFilters(appState.filters, enabled: appState.quotaCardProviders)
        let current = appState.usageDisplaySnapshot(filters: filters, now: Date())
        if let current { memory.last = current }
        // Between a new period and its response there is no snapshot: the
        // previous figures stay, faded (134r), as in 近期消耗.
        return ModernDetailsGrid(
            snapshot: current ?? memory.last,
            isStale: current == nil && memory.last != nil,
            isLoading: appState.isLoadingData,
            openRemainder: openRemainder
        )
    }
}

/// The last snapshot this section drew. Not observed: writing it from `body`
/// never schedules another update.
@MainActor
private final class SnapshotMemory {
    var last: UsageDisplaySnapshot?
}

/// What a card shows in place of figures.
private enum DetailsPhase {
    case figures
    /// First load: loading blocks where the numbers go (134q).
    case loading
    /// Nothing in this period with these filters: an empty ring around a
    /// faded zero (134s).
    case empty
}

private struct ModernDetailsGrid: View {
    @Environment(AppState.self) private var appState
    @Environment(\.controlActiveState) private var windowState
    let snapshot: UsageDisplaySnapshot?
    let isStale: Bool
    let isLoading: Bool
    @State private var openRemainder: UsageRanking.Dimension?
    @State private var dismissal = RemainderDismissal()

    init(snapshot: UsageDisplaySnapshot?, isStale: Bool, isLoading: Bool, openRemainder: UsageRanking.Dimension?) {
        self.snapshot = snapshot
        self.isStale = isStale
        self.isLoading = isLoading
        _openRemainder = State(initialValue: openRemainder)
    }

    private var phase: DetailsPhase {
        guard let snapshot else { return isLoading ? .loading : .empty }
        return snapshot.grid.slots.isEmpty ? .empty : .figures
    }

    var body: some View {
        VStack(spacing: ModernTheme.cardSpacing) {
            HStack(spacing: ModernTheme.cardSpacing) {
                distribution(.model, title: "模型分布")
                ModernDetailCard(
                    title: "Token 构成", metric: .tokens, ranking: snapshot?.tokenComposition,
                    phase: phase, isStale: isStale, namesAreDynamic: false
                )
            }
            HStack(spacing: ModernTheme.cardSpacing) {
                distribution(.terminal, title: "终端分布")
                distribution(.tool, title: "工具分布")
            }
        }
        .overlayPreferenceValue(RemainderAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let open = openRemainder, let anchor = anchors[open], let snapshot {
                    let rows = Array(snapshot.ranking(open, by: appState.modernPanel[metricFor: open]).remainder)
                    if !rows.isEmpty {
                        remainderList(rows, metric: appState.modernPanel[metricFor: open],
                                      trigger: proxy[anchor], in: proxy)
                    }
                }
            }
        }
        .onChange(of: openRemainder) { _, open in
            if open == nil {
                dismissal.stop()
            } else {
                dismissal.start { openRemainder = nil }
            }
        }
        .onChange(of: windowState) { _, state in
            if state != .key { openRemainder = nil }
        }
        .onAppear {
            if openRemainder != nil { dismissal.start { openRemainder = nil } }
        }
        .onDisappear { dismissal.stop() }
    }

    private func distribution(_ dimension: UsageRanking.Dimension, title: String) -> some View {
        let metric = appState.modernPanel[metricFor: dimension]
        return ModernDetailCard(
            title: title, metric: metric, ranking: snapshot?.ranking(dimension, by: metric),
            phase: phase, isStale: isStale, namesAreDynamic: true,
            remainder: (dimension, {
                openRemainder = openRemainder == dimension ? nil : dimension
            }),
            selectMetric: { appState.modernPanel[metricFor: dimension] = $0 }
        )
    }

    /// 135d: the rest of the ranking, in a small raised list that continues
    /// the card's own rows (same columns), under 「其余 N 个」. A list that
    /// would leave the grid opens above the row instead (the bottom cards);
    /// a long one scrolls.
    private func remainderList(_ rows: [UsageRanking.Row], metric: MetricMode,
                               trigger: CGRect, in proxy: GeometryProxy) -> some View {
        let frame = RemainderListPlacement.frame(trigger: trigger, rows: rows.count, container: proxy.size)
        let origin = proxy.frame(in: .global).origin
        dismissal.list = frame.offsetBy(dx: origin.x, dy: origin.y)
        dismissal.trigger = trigger.offsetBy(dx: origin.x, dy: origin.y)
        let scrolls = frame.height < RemainderListPlacement.height(rows: rows.count)
        return ModernRemainderList(rows: rows, metric: metric, scrolls: scrolls)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }
}

/// Where 「其余 N 个」 opens its list (135d): 2 pt under the row, inset so
/// its rows line up with the card's (9 pt padding on a 7 pt inset); above
/// the row when the grid ends first. A longer list than ten rows shows nine
/// and a half, so the cut row says there is more to scroll.
enum RemainderListPlacement {
    static let rowHeight: CGFloat = 22
    static let verticalPadding: CGFloat = 5
    static let horizontalPadding: CGFloat = 9
    static let gap: CGFloat = 2
    static let maxVisibleRows = 10
    /// The fade at the bottom of a list that scrolls.
    static let fade: CGFloat = 14

    static func height(rows: Int) -> CGFloat {
        2 * verticalPadding + rowHeight * CGFloat(rows)
    }

    static func visibleHeight(rows: Int) -> CGFloat {
        rows > maxVisibleRows ? verticalPadding + rowHeight * (CGFloat(maxVisibleRows) - 0.5) : height(rows: rows)
    }

    static func frame(trigger: CGRect, rows: Int, container: CGSize) -> CGRect {
        let height = visibleHeight(rows: rows)
        let below = trigger.maxY + gap
        let above = trigger.minY - gap - height
        let y = below + height <= container.height || above < 0 ? below : above
        return CGRect(x: trigger.minX - horizontalPadding, y: y,
                      width: trigger.width + 2 * horizontalPadding, height: height)
    }
}

/// Each card's 「其余 N 个」 row, for the grid to hang the list from.
private struct RemainderAnchorKey: PreferenceKey {
    static var defaultValue: [UsageRanking.Dimension: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [UsageRanking.Dimension: Anchor<CGRect>],
                       nextValue: () -> [UsageRanking.Dimension: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Closes the open list on a click anywhere outside it and its row, like a
/// menu; the click still goes where it was aimed (a period, another card's
/// switch). Escape keeps closing the whole panel.
@MainActor
private final class RemainderDismissal {
    /// Both in the hosting view's top-left space (SwiftUI's global space).
    var list: CGRect = .null
    var trigger: CGRect = .null
    private var monitor: Any?

    func start(close: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.isInside(event) else { return }
                close()
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func isInside(_ event: NSEvent) -> Bool {
        // The hosting view fills the panel's content view, which is not
        // flipped.
        guard let content = event.window?.contentView else { return false }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        return list.contains(point) || trigger.contains(point)
    }
}

// MARK: - Card

/// One card: title (with the Token / 费用 switch on the three distributions),
/// the ring 12 pt below it, then the rows.
private struct ModernDetailCard: View {
    let title: String
    let metric: MetricMode
    let ranking: UsageRanking?
    let phase: DetailsPhase
    let isStale: Bool
    /// Model, terminal and tool names come from the data and can be long:
    /// they truncate in the middle and show in full on hover.
    let namesAreDynamic: Bool
    /// 「其余 N 个」: the dimension and what opens or closes its list.
    var remainder: (dimension: UsageRanking.Dimension, toggle: () -> Void)?
    var selectMetric: ((MetricMode) -> Void)?

    var body: some View {
        ModernCard(title: title) {
            if let selectMetric {
                ModernMetricSwitch(metric: metric, select: selectMetric)
            }
        } content: {
            VStack(spacing: 12) {
                ring
                rows
            }
            .padding(.top, 4)
            .frame(height: 252 - 2 * ModernTheme.cardPadding - 20 - 8, alignment: .top)
            .opacity(isStale ? 0.38 : 1)
        }
    }

    private var figures: UsageRanking? { phase == .figures ? ranking : nil }

    private var ring: some View {
        ZStack {
            ModernDistributionRing(segments: segments)
            VStack(spacing: 0) {
                switch phase {
                case .figures:
                    centerValue(DetailsFormat.value(ranking?.total ?? 0, metric))
                case .loading:
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(ModernTheme.placeholder)
                        .frame(width: 44, height: 10)
                        .frame(height: 16)
                case .empty:
                    centerValue(DetailsFormat.value(0, metric)).opacity(0.3)
                }
                Text(metric.label)
                    .font(metric == .tokens ? ModernTheme.mono(11) : ModernTheme.text(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .frame(height: 14)
            }
        }
        .frame(width: ModernDistributionRing.size, height: ModernDistributionRing.size)
    }

    private func centerValue(_ text: String) -> some View {
        Text(text)
            .font(ModernTheme.mono(13, .medium))
            .foregroundStyle(ModernTheme.text)
            .lineLimit(1)
            // A five-figure spend still fits inside the ticks.
            .minimumScaleFactor(0.75)
            .frame(maxWidth: 62)
            .frame(height: 16)
    }

    private var segments: [ModernDistributionRing.Segment] {
        guard let figures else { return [] }
        var segments = figures.top.map { ModernDistributionRing.Segment(value: $0.value, color: $0.color.swatch) }
        if !figures.remainder.isEmpty {
            segments.append(.init(value: figures.remainderValue, color: UsageRanking.RankColor.gray.swatch))
        }
        return segments
    }

    @ViewBuilder
    private var rows: some View {
        VStack(spacing: 0) {
            if let figures {
                ForEach(Array(figures.top.enumerated()), id: \.offset) { _, row in
                    ModernDetailRow(row: row, metric: metric, namesAreDynamic: namesAreDynamic)
                }
                if let remainder, !figures.remainder.isEmpty {
                    remainderRow(figures, remainder)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func remainderRow(_ figures: UsageRanking,
                              _ remainder: (dimension: UsageRanking.Dimension, toggle: () -> Void))
        -> some View {
        Button(action: remainder.toggle) {
            ModernDetailRowLayout(
                swatch: UsageRanking.RankColor.gray.swatch,
                name: Text("其余 ") + Text("\(figures.remainder.count)").font(ModernTheme.mono(13, .medium)) + Text(" 个"),
                value: DetailsFormat.value(figures.remainderValue, metric),
                share: figures.total > 0 ? figures.remainderValue / figures.total : 0
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ModernTextButtonStyle(color: ModernTheme.secondaryText))
        .anchorPreference(key: RemainderAnchorKey.self, value: .bounds) { [remainder.dimension: $0] }
        .accessibilityLabel("其余 \(figures.remainder.count) 个")
    }
}

/// The Token / 费用 pair at the right of a distribution card's title: the
/// period chips' look, the selected one lit. Its text edge stays on the
/// card's 28 pt line (the chip padding hangs past it).
private struct ModernMetricSwitch: View {
    let metric: MetricMode
    let select: (MetricMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            chip(.tokens)
            chip(.cost)
        }
        .padding(.trailing, -8)
    }

    private func chip(_ option: MetricMode) -> some View {
        let isOn = option == metric
        let weight: Font.Weight = isOn ? .medium : .regular
        return Button {
            select(option)
        } label: {
            Text(option.label)
                .font(option == .tokens ? ModernTheme.mono(11, weight) : ModernTheme.text(11, weight))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(isOn ? ModernTheme.chip : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(ModernTextButtonStyle(color: isOn ? ModernTheme.text : ModernTheme.secondaryText))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Rows

/// A ranked row: rank swatch, name, value and share.
private struct ModernDetailRow: View {
    let row: UsageRanking.Row
    let metric: MetricMode
    let namesAreDynamic: Bool
    /// The remainder list's rows: gray swatches, full-strength names.
    var swatch: Color?

    var body: some View {
        ModernDetailRowLayout(
            swatch: swatch ?? row.color.swatch,
            name: Text(row.name),
            value: DetailsFormat.value(row.value, metric),
            share: row.share,
            truncatesInMiddle: namesAreDynamic
        )
        .foregroundStyle(ModernTheme.text)
        .help(namesAreDynamic ? row.name : "")
    }
}

/// Columns of a row (135a): a 7 pt swatch, 7 pt, the name (gives way when
/// long), at least 8 pt, the value, and the share right-aligned in 32 pt.
/// Name and value take the inherited color; the share stays secondary.
private struct ModernDetailRowLayout: View {
    let swatch: Color
    let name: Text
    let value: String
    let share: Double
    var truncatesInMiddle = false

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(swatch)
                .frame(width: 7, height: 7)
                .padding(.trailing, 7)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                name
                    .font(ModernTheme.text(13, .medium))
                    .lineLimit(1)
                    .truncationMode(truncatesInMiddle ? .middle : .tail)
                Spacer(minLength: 8)
                Text(value)
                    .font(ModernTheme.mono(13, .medium))
                    .tracking(-0.26)
                    .fixedSize()
                Text(DetailsFormat.share(share))
                    .font(ModernTheme.mono(11))
                    .foregroundStyle(ModernTheme.secondaryText)
                    .frame(width: 32, alignment: .trailing)
                    .fixedSize()
            }
        }
        .frame(height: RemainderListPlacement.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// 135d's list: a raised card a step lighter than the cards, with the
/// remaining rows in the card's columns.
private struct ModernRemainderList: View {
    let rows: [UsageRanking.Row]
    let metric: MetricMode
    let scrolls: Bool

    var body: some View {
        Group {
            if scrolls {
                // No scroller: with a mouse attached it would take width
                // from the columns; the last row, cut and fading out, shows
                // there is more.
                ScrollView(.vertical) { list }
                    .scrollIndicators(.never)
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: RemainderListPlacement.fade)
                        }
                    }
            } else {
                list
            }
        }
        .padding(.horizontal, RemainderListPlacement.horizontalPadding)
        .background {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            shape
                .fill(LinearGradient(colors: [Color(settingsHex: 0x2A2E34), Color(settingsHex: 0x22262B)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    // `inset 0 1px 0 rgba(255,255,255,.08)`
                    shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        .mask(alignment: .top) {
                            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 9)
                        }
                }
                .shadow(color: .black.opacity(0.5), radius: 11, y: 8)
                .overlay { shape.inset(by: -1).strokeBorder(Color.black.opacity(0.45), lineWidth: 1) }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                ModernDetailRow(row: row, metric: metric, namesAreDynamic: true,
                                swatch: UsageRanking.RankColor.gray.swatch)
            }
        }
        .padding(.top, RemainderListPlacement.verticalPadding)
        // Scrolled to the end, the last row clears the fade.
        .padding(.bottom, RemainderListPlacement.verticalPadding + (scrolls ? RemainderListPlacement.fade : 0))
    }
}

// MARK: - Ring

/// 72 radial ticks around the total (135a): each share gets its run of
/// ticks clockwise from the top in rank order, the last tick of every run
/// left dark as the gap to the next. One share alone is a closed ring;
/// without figures every tick is off.
struct ModernDistributionRing: View {
    struct Segment {
        let value: Double
        let color: Color
    }

    static let size: CGFloat = 88
    nonisolated static let tickCount = 72
    nonisolated private static let innerRadius: CGFloat = 34
    nonisolated private static let outerRadius: CGFloat = 43
    private static let lineWidth: CGFloat = 1.7

    let segments: [Segment]

    var body: some View {
        let owners = Self.tickOwners(segments.map(\.value))
        ZStack {
            Ticks(indices: owners.indices.filter { owners[$0] == nil })
                .stroke(segments.isEmpty ? ModernTheme.ringOff : ModernTheme.ringGap, lineWidth: Self.lineWidth)
            ForEach(segments.indices, id: \.self) { segment in
                Ticks(indices: owners.indices.filter { owners[$0] == segment })
                    .stroke(segments[segment].color, lineWidth: Self.lineWidth)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }

    /// For each tick, the segment it belongs to, or nil for a gap (or for
    /// every tick when nothing has a value). Each positive share gets at
    /// least one tick; the rest follow the largest remainders, so the runs
    /// always add up to the whole ring.
    nonisolated static func tickOwners(_ values: [Double], count: Int = tickCount) -> [Int?] {
        let sum = values.reduce(0) { $0 + max($1, 0) }
        guard sum > 0 else { return Array(repeating: nil, count: count) }
        let exact = values.map { max($0, 0) / sum * Double(count) }
        var runs = exact.map { $0 > 0 ? max(1, Int($0.rounded(.down))) : 0 }
        var left = count - runs.reduce(0, +)
        let byRemainder = exact.indices.filter { exact[$0] > 0 }.sorted {
            exact[$0] - exact[$0].rounded(.down) > exact[$1] - exact[$1].rounded(.down)
        }
        while left > 0 {
            for index in byRemainder where left > 0 {
                runs[index] += 1
                left -= 1
            }
        }
        // Minimum ticks for tiny shares come out of the longest run.
        while left < 0, let longest = runs.indices.max(by: { runs[$0] < runs[$1] }) {
            runs[longest] -= 1
            left += 1
        }
        let separated = runs.filter { $0 > 0 }.count > 1
        var owners: [Int?] = []
        for (segment, run) in runs.enumerated() where run > 0 {
            let lit = separated && run > 1 ? run - 1 : run
            owners += Array(repeating: segment, count: lit)
            owners += Array(repeating: nil, count: run - lit)
        }
        return owners
    }

    private struct Ticks: Shape {
        let indices: [Int]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            for index in indices {
                let angle = (Double(index) + 0.5) / Double(ModernDistributionRing.tickCount) * 2 * .pi
                let direction = CGVector(dx: sin(angle), dy: -cos(angle))
                path.move(to: CGPoint(x: center.x + direction.dx * ModernDistributionRing.innerRadius,
                                      y: center.y + direction.dy * ModernDistributionRing.innerRadius))
                path.addLine(to: CGPoint(x: center.x + direction.dx * ModernDistributionRing.outerRadius,
                                         y: center.y + direction.dy * ModernDistributionRing.outerRadius))
            }
            return path
        }
    }
}

// MARK: - Palette and numbers

extension ModernTheme {
    /// Rank colors (design §4): only on swatches and ring ticks, never on text.
    static let rankBlue = Color(settingsHex: 0x608ECA)
    static let rankTeal = Color(settingsHex: 0x4EB397)
    static let rankMagenta = Color(settingsHex: 0x9C5B88)
    static let rankGray = text.opacity(0.26)
    /// The rings' warm white, `rgb(237,233,225)`: unlit ticks at 13%, the
    /// gap between two shares at 7%.
    static let ringOff = Color(red: 237 / 255, green: 233 / 255, blue: 225 / 255).opacity(0.13)
    static let ringGap = Color(red: 237 / 255, green: 233 / 255, blue: 225 / 255).opacity(0.07)
}

private extension UsageRanking.RankColor {
    var swatch: Color {
        switch self {
        case .blue: ModernTheme.rankBlue
        case .teal: ModernTheme.rankTeal
        case .magenta: ModernTheme.rankMagenta
        case .gray: ModernTheme.rankGray
        }
    }
}

enum DetailsFormat {
    /// The card's metric, in the app's existing formats.
    static func value(_ value: Double, _ metric: MetricMode) -> String {
        switch metric {
        case .tokens: Formatters.formatNumber(Int(value.rounded()))
        case .cost: Formatters.formatCost(value)
        }
    }

    /// Whole percent; a share too small to round to 1% still reads as present.
    static func share(_ share: Double) -> String {
        let percent = Int((share * 100).rounded())
        if percent == 0 && share > 0 { return "<1%" }
        return "\(percent)%"
    }
}
