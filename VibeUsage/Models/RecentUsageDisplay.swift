import Foundation

// What the new panel's 近期消耗 card draws (design 134), from a
// `UsageDisplaySnapshot`, the activity report and the panel's units. Pure
// values: the card only lays them out. The totals, slots and units come from
// the usage rules (#105); this file only turns them into labels and positions.

/// One piece of the big number (134a, 134l–134o): the currency sign, the
/// decimals and the units are set small, the integer large.
struct RecentUsageNumberPart: Equatable {
    enum Role: Equatable { case symbol, integer, fraction, unit }
    let text: String
    let role: Role
}

enum RecentUsageNumber {
    /// Splits a formatted figure ("$41.20", "65.5M", "6550万", "3h 12m",
    /// "1,234") for the big number. A cost of 100 or more is drawn without
    /// its cents (134d, 134i), rounded; the exact value is in the hover.
    static func parts(_ formatted: String, dropsCentsFromHundred: Bool = false) -> [RecentUsageNumberPart] {
        // ASCII digits only: 万 and 亿 count as numbers to `Character.isNumber`.
        func isDigit(_ character: Character) -> Bool { character.isASCII && character.isNumber }
        guard formatted.contains(where: isDigit) else { return [.init(text: formatted, role: .integer)] }
        var parts: [RecentUsageNumberPart] = []
        var rest = Substring(formatted)
        let symbol = rest.prefix { !isDigit($0) }
        if !symbol.isEmpty { parts.append(.init(text: String(symbol), role: .symbol)) }
        rest = rest.dropFirst(symbol.count)
        while let first = rest.first {
            if isDigit(first) || first == "," {
                let digits = rest.prefix { isDigit($0) || $0 == "," }
                parts.append(.init(text: String(digits), role: .integer))
                rest = rest.dropFirst(digits.count)
            } else if first == ".", let next = rest.dropFirst().first, isDigit(next) {
                let digits = rest.dropFirst().prefix(while: isDigit)
                parts.append(.init(text: String(digits), role: .fraction))
                rest = rest.dropFirst(1 + digits.count)
            } else if first == " " {
                rest = rest.dropFirst()
            } else {
                let unit = rest.prefix { !isDigit($0) && $0 != " " }
                parts.append(.init(text: String(unit), role: .unit))
                rest = rest.dropFirst(unit.count)
            }
        }
        if dropsCentsFromHundred,
           let index = parts.firstIndex(where: { $0.role == .integer }),
           let whole = Int(parts[index].text),
           index + 1 < parts.count, parts[index + 1].role == .fraction {
            let fraction = parts[index + 1].text
            let cents = Int(fraction.prefix(2).padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
            // Nothing spent reads 「$0」 (134s).
            if whole >= 100 || whole == 0 && fraction.allSatisfy({ $0 == "0" }) {
                parts[index] = .init(text: String(cents >= 50 ? whole + 1 : whole), role: .integer)
                parts.remove(at: index + 1)
            }
        }
        return parts
    }

    /// Durations as drawn: 「3h 12m」「19h 05m」「47h」「48m」, and 「0m」 for
    /// none. The classic panel keeps `ActivityTime.duration`.
    static func duration(_ seconds: Int) -> String {
        if seconds <= 0 { return "0m" }
        if seconds < 60 { return "\(seconds)s" }
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        if hours == 0 { return "\(minutes)m" }
        return minutes == 0 ? "\(hours)h" : String(format: "%dh %02dm", hours, minutes)
    }

    /// The new panel writes the yuan sign as drawn (¥), not the full-width
    /// one the shared formatter uses: a full-width sign leaves a gap in the
    /// monospaced figures.
    static func cost(_ usd: Double, units: UsagePanelState) -> String {
        units.formatCost(usd).replacingOccurrences(of: "￥", with: "¥")
    }
}

/// The figures of the card's three metrics, in the panel's current units.
struct RecentUsageFigures {
    let total: UsageAmount
    /// Deduplicated active time; nil until the server has recorded any (「—」).
    let activity: ActivityTime?
    let units: UsagePanelState

    /// The big number or a small row's value.
    func text(_ metric: ChartMode) -> String {
        switch metric {
        case .cost: RecentUsageNumber.cost(total.cost, units: units)
        case .token: units.formatTokens(total.totalTokens)
        case .activeTime: activity.map { RecentUsageNumber.duration($0.activeSeconds) } ?? "—"
        }
    }

    /// The exact value shown when the pointer rests on the big number (134p).
    func exactText(_ metric: ChartMode) -> String? {
        switch metric {
        case .cost:
            let value = units.usesCNY ? total.cost * 7 : total.cost
            return String(format: "%@%.4f", units.usesCNY ? "¥" : "$", value)
        case .token:
            return total.totalTokens.formatted(.number.locale(Locale(identifier: "en_US")))
        case .activeTime:
            return nil
        }
    }

    /// The other unit the big number switches to when clicked.
    func unitHint(_ metric: ChartMode) -> String? {
        switch metric {
        case .cost: units.usesCNY ? "点一下换成美元" : "点一下换成人民币"
        case .token: units.usesChineseTokens ? "点一下换成 M、B" : "点一下换成万、亿"
        case .activeTime: nil
        }
    }

    static func label(_ metric: ChartMode) -> String {
        switch metric {
        case .cost: "预估费用"
        case .token: "总 Token"
        case .activeTime: "活跃时长"
        }
    }

    static func rowLabel(_ metric: ChartMode) -> String {
        switch metric {
        case .cost: "费用"
        case .token: "Token"
        case .activeTime: "活跃"
        }
    }

    /// The two small rows under the big number, in a fixed order.
    static func rows(besides hero: ChartMode) -> [ChartMode] {
        [ChartMode.cost, .token, .activeTime].filter { $0 != hero }
    }
}

/// What the pointer shows on the curve (134b, 134c, 134l).
enum RecentUsageTooltip: Equatable {
    /// One line: the period and its value.
    case line(period: String, value: String)
    /// The period over a small table (the Token or activity breakdown).
    case table(period: String, rows: [Row])

    struct Row: Equatable {
        let label: String
        let value: String
    }
}

/// The curve of one metric over the snapshot's slots, its peak, the axis
/// labels and each slot's hover content (134a–134d, 134i, 134l, 134m).
/// Positions are fractions of the plot width: time runs left to right from
/// the first slot's start to the last slot's end.
struct RecentUsageChart {
    struct Point: Equatable {
        let x: Double
        let value: Double
    }

    struct Tick: Equatable {
        let x: Double
        let label: String
    }

    /// The points the curve passes through, left edge to right edge.
    let curve: [Point]
    /// One per slot, in slot order: where the pointer snaps and what it shows.
    let hoverPoints: [Point]
    let tooltips: [RecentUsageTooltip]
    let peak: Double
    let peakLabel: String
    let startLabel: String
    /// 「现在」, 「今天」 or the last day.
    let endLabel: String
    /// The two labelled ticks between them.
    let ticks: [Tick]

    init(snapshot: UsageDisplaySnapshot, metric: ChartMode, activity: [ActivityTime?],
         units: UsagePanelState, rolling: Bool, now: Date, calendar: Calendar = .current) {
        let slots = snapshot.grid.slots
        let kind = SlotKind(slots)
        let span = max(1, (slots.last?.end ?? now).timeIntervalSince(slots.first?.start ?? now))
        func position(_ date: Date) -> Double {
            guard let first = slots.first else { return 0 }
            return min(1, max(0, date.timeIntervalSince(first.start) / span))
        }

        var values: [Double] = []
        var tooltips: [RecentUsageTooltip] = []
        let labels = SlotLabels(calendar: calendar, now: now)
        for (index, point) in snapshot.series.enumerated() {
            let period = labels.period(DateInterval(start: point.start, end: point.end), kind: kind)
            switch metric {
            case .cost:
                values.append(point.amount.cost)
                tooltips.append(.line(period: period, value: RecentUsageNumber.cost(point.amount.cost, units: units)))
            case .token:
                let amount = point.amount
                values.append(Double(amount.totalTokens))
                tooltips.append(.table(period: period, rows: [
                    .init(label: "总 Token", value: units.formatTokens(amount.totalTokens)),
                    .init(label: "输出", value: units.formatTokens(amount.output)),
                    .init(label: "输入", value: units.formatTokens(amount.input)),
                    .init(label: "缓存", value: units.formatTokens(amount.cached)),
                ]))
            case .activeTime:
                let time = index < activity.count ? activity[index] : nil
                values.append(Double(time?.activeSeconds ?? 0))
                if let time {
                    var rows = [RecentUsageTooltip.Row(label: "活跃", value: RecentUsageNumber.duration(time.activeSeconds))]
                    if time.workSeconds > 0 {
                        rows.append(.init(label: "AI 工时", value: RecentUsageNumber.duration(time.workSeconds)))
                    }
                    if let parallel = time.parallelText {
                        rows.append(.init(label: "平均同时",
                                          value: String(parallel.dropFirst("平均同时 ".count))))
                    }
                    tooltips.append(.table(period: period, rows: rows))
                } else {
                    tooltips.append(.line(period: period, value: "—"))
                }
            }
        }

        // Slots sit at their middle; the last one at the right edge, where
        // the dot is. A fixed-start period grows from zero at its left edge;
        // the rolling 24 hours start at their first value (134a, 134c).
        var hoverPoints: [Point] = []
        for (index, slot) in slots.enumerated() {
            let x = index == slots.count - 1 ? 1 : position(slot.start.addingTimeInterval(slot.duration / 2))
            hoverPoints.append(Point(x: x, value: values[index]))
        }
        var curve = hoverPoints
        if let first = values.first, hoverPoints.first?.x ?? 0 > 0 {
            curve.insert(Point(x: 0, value: rolling ? first : 0), at: 0)
        }
        self.curve = curve
        self.hoverPoints = hoverPoints
        self.tooltips = tooltips
        peak = values.max() ?? 0
        peakLabel = RecentUsageChart.axisLabel(peak, metric: metric, units: units)

        startLabel = slots.first.map { labels.start($0, kind: kind) } ?? ""
        endLabel = slots.last.map { labels.end($0, kind: kind) } ?? ""
        ticks = RecentUsageChart.tickSlots(slots, kind: kind).compactMap { index in
            let x = position(slots[index].start)
            guard x > 0.12, x < 0.85 else { return nil }
            return Tick(x: x, label: labels.tick(slots[index].start, kind: kind))
        }
    }

    /// The peak's label (top left): two significant digits or so, in the
    /// panel's units — 「$9.4」, 「$63」, 「15M」, 「1510万」, 「48m」.
    static func axisLabel(_ value: Double, metric: ChartMode, units: UsagePanelState) -> String {
        switch metric {
        case .cost:
            let text = RecentUsageNumber.cost(value, units: units)
            guard let symbol = text.first, let amount = Double(text.dropFirst()) else { return text }
            if amount >= 10 { return "\(symbol)\(Int(amount.rounded()))" }
            if amount < 0.01 { return text }
            var digits = String(format: amount >= 1 ? "%.1f" : "%.2f", amount)
            while digits.hasSuffix("0") { digits.removeLast() }
            if digits.hasSuffix(".") { digits.removeLast() }
            return "\(symbol)\(digits)"
        case .token:
            let text = units.formatTokens(Int(value.rounded()))
            guard !units.usesChineseTokens, let unit = text.last, "KMB".contains(unit),
                  let mantissa = Double(text.dropLast()) else { return text }
            if mantissa >= 10 { return "\(Int(mantissa.rounded()))\(unit)" }
            var short = String(format: "%.1f", mantissa)
            if short.hasSuffix(".0") { short.removeLast(2) }
            return "\(short)\(unit)"
        case .activeTime:
            return RecentUsageNumber.duration(Int(value.rounded()))
        }
    }

    /// Two labelled boundaries about a third and two thirds in. Hours step
    /// in round amounts from the first whole hour (9:00 → 11:00, 13:00;
    /// 昨天 16:00 → 0:00, 8:00); days and weeks in whole slots.
    static func tickSlots(_ slots: [DateInterval], kind: SlotKind) -> [Int] {
        guard slots.count > 2 else { return [] }
        let base = kind == .hour && slots[0].duration < 3_599 ? 1 : 0
        let third = Double(slots.count - base) / 3
        let step: Int
        if kind == .hour {
            step = [1, 2, 3, 4, 6, 8, 12].min { abs(Double($0) - third) < abs(Double($1) - third) } ?? 1
        } else {
            step = max(1, Int(third.rounded()))
        }
        return [base + step, base + 2 * step].filter { $0 < slots.count }
    }

    enum SlotKind: Equatable {
        case hour, day, week

        init(_ slots: [DateInterval]) {
            if slots.allSatisfy({ $0.duration <= 3_601 }) {
                self = .hour
            } else if slots.contains(where: { $0.duration > 2 * 86_400 }) {
                self = .week
            } else {
                self = .day
            }
        }
    }

    /// The activity curve: active and work seconds per slot, from the
    /// report's periods (`UsagePlotGrid.sums`). Slots before the first
    /// recorded instant are unknown (nil); later ones without a period were
    /// idle. A report of the other granularity (a single custom day draws
    /// hours, activity answers by day) adds nothing.
    static func activity(_ report: ActivityReport?, grid: UsagePlotGrid) -> [ActivityTime?] {
        let slots = grid.slots
        guard let report, report.isHourly == (SlotKind(slots) == .hour) else {
            return Array(repeating: nil, count: slots.count)
        }
        let active = grid.sums(report.activeSecondsByStart)
        let work = grid.sums(report.workSecondsByStart)
        return slots.indices.map { index in
            guard let first = report.firstRecorded, slots[index].end > first else { return nil }
            let seconds = active[index] ?? 0
            let workSeconds = work[index] ?? 0
            let parallel: Double? = seconds > 0
                ? max(1, (10 * Double(workSeconds) / Double(seconds)).rounded() / 10)
                : nil
            return ActivityTime(activeSeconds: seconds, workSeconds: workSeconds, parallel: parallel)
        }
    }
}

/// Clock and calendar labels for the axis and the hover.
private struct SlotLabels {
    let calendar: Calendar
    let now: Date

    private func time(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }

    /// 「昨天 」 or 「11/18 」 before a time that is not today.
    private func dayPrefix(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "昨天 " }
        return day(date) + " "
    }

    func period(_ slot: DateInterval, kind: RecentUsageChart.SlotKind) -> String {
        switch kind {
        case .hour:
            let end = calendar.startOfDay(for: slot.end) == slot.end && slot.end > slot.start
                && !calendar.isDate(slot.start, inSameDayAs: slot.end) ? "24:00" : time(slot.end)
            return "\(dayPrefix(slot.start))\(time(slot.start))–\(end)"
        case .day:
            return day(slot.start)
        case .week:
            let last = slot.end.addingTimeInterval(-1)
            return calendar.isDate(slot.start, inSameDayAs: last) ? day(slot.start) : "\(day(slot.start))–\(day(last))"
        }
    }

    func start(_ slot: DateInterval, kind: RecentUsageChart.SlotKind) -> String {
        guard kind == .hour else { return day(slot.start) }
        // A clipped first hour (the rolling day) is labelled at its hour.
        let hour = calendar.dateInterval(of: .hour, for: slot.start)?.start ?? slot.start
        return dayPrefix(hour) + time(hour)
    }

    func end(_ slot: DateInterval, kind: RecentUsageChart.SlotKind) -> String {
        let isNow = abs(slot.end.timeIntervalSince(now)) < 1
        switch kind {
        case .hour:
            if isNow { return "现在" }
            return calendar.startOfDay(for: slot.end) == slot.end ? "24:00" : time(slot.end)
        case .day, .week:
            return isNow ? "今天" : day(slot.end.addingTimeInterval(-1))
        }
    }

    func tick(_ date: Date, kind: RecentUsageChart.SlotKind) -> String {
        kind == .hour ? time(date) : day(date)
    }
}

/// The chips and the menu's values for the filters (134f–134k).
enum UsageFilterSummary {
    /// 「Codex」, 「Codex +1」: the first name in reading order and how many
    /// more; nil without a selection.
    static func label(_ names: [String]) -> String? {
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let first = sorted.first else { return nil }
        return sorted.count == 1 ? first : "\(first) +\(sorted.count - 1)"
    }

    /// 「11/3–11/18」.
    static func customLabel(from: Date, to: Date, calendar: Calendar = .current) -> String {
        func day(_ date: Date) -> String {
            let parts = calendar.dateComponents([.month, .day], from: date)
            return "\(parts.month ?? 0)/\(parts.day ?? 0)"
        }
        return calendar.isDate(from, inSameDayAs: to) ? day(from) : "\(day(from))–\(day(to))"
    }

    /// The quick periods in the title row and the time submenu.
    static let quickPeriods: [TimeRange] = [.today, .oneDay, .sevenDays, .thirtyDays, .ninetyDays]

    static func periodLabel(_ range: TimeRange) -> String {
        switch range {
        case .today: "今天"
        case .oneDay: "24H"
        case .sevenDays, .thirtyDays, .ninetyDays: range.rawValue
        case .custom: "自定义日期"
        }
    }
}
