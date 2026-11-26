import Foundation

struct UsageAmount: Equatable {
    private(set) var input = 0
    private(set) var output = 0
    private(set) var cached = 0
    private(set) var cost = 0.0
    var totalTokens: Int { input + output + cached }

    fileprivate mutating func add(_ bucket: UsageBucket) {
        input += bucket.inputIncludingCacheWrites
        output += bucket.outputTokens + bucket.reasoningOutputTokens
        cached += bucket.cachedInputTokens
        cost += bucket.estimatedCost ?? 0
    }

    /// Active time comes from the dedicated activity series, independently of token usage.
    func value(for metric: ChartMode) -> Double? {
        switch metric {
        case .cost: cost
        case .token: Double(totalTokens)
        case .activeTime: nil
        }
    }
}

struct UsageSeriesPoint {
    let start: Date
    let end: Date
    let amount: UsageAmount
}

/// Built from one response and a fixed clock. Hover reads an existing point by index.
struct UsageDisplaySnapshot {
    private(set) var total = UsageAmount()
    private(set) var series: [UsageSeriesPoint] = []
    private(set) var peakTokens = 0
    private(set) var peakCost = 0.0
    private(set) var tokenComposition = UsageRanking.empty
    private var rankings: [UsageRanking.Dimension: (tokens: UsageRanking, cost: UsageRanking)] = [:]

    init(buckets: [UsageBucket], range: TimeRange, customDays: ClosedRange<Date>? = nil,
         filters: UsagePanelFilters = .init(), modelName: (String) -> String = { $0 },
         toolName: (String) -> String = { $0 },
         now: Date, calendar: Calendar = .current) {
        guard let window = UsagePlotWindow(range, customDays: customDays, now: now, calendar: calendar) else { return }
        let firstSlot = window.slot(containing: window.start)
        // Even a single custom day can arrive as UTC hours. Its first row may
        // be labelled before local midnight in a fractional-offset time zone.
        let firstServerHour = UsagePlotWindow.utcHour(containing: window.start)
        var amounts: [Date: UsageAmount] = [:]
        var groups: [UsageRanking.Dimension: [String: UsageAmount]] = [:]
        for bucket in buckets {
            let model = modelName(bucket.model)
            guard filters.includes(bucket, modelName: model), let date = bucket.date,
                  date <= now, date < window.endExclusive,
                  date >= window.start || date == firstServerHour else { continue }
            let slot = window.slot(containing: max(date, window.start))
            amounts[slot, default: UsageAmount()].add(bucket)
            total.add(bucket)
            let tool = toolName(bucket.source)
            let terminal = bucket.hostname
            groups[.model, default: [:]][model.isEmpty ? "未知" : model, default: .init()].add(bucket)
            groups[.tool, default: [:]][tool.isEmpty ? "未知" : tool, default: .init()].add(bucket)
            groups[.terminal, default: [:]][terminal.isEmpty ? "未知" : terminal, default: .init()].add(bucket)
        }

        guard let firstUsage = amounts.keys.min() else { return }
        tokenComposition = UsageRanking(values: ["缓存": Double(total.cached), "输入": Double(total.input),
                                                 "输出": Double(total.output)])
        rankings = groups.mapValues { names in
            (tokens: UsageRanking(values: names.mapValues { Double($0.totalTokens) }),
             cost: UsageRanking(values: names.mapValues(\.cost)))
        }
        var slot = range == .today ? firstUsage : firstSlot
        while slot <= now && slot < window.endExclusive {
            let amount = amounts[slot] ?? UsageAmount()
            let next = window.nextSlot(after: slot)
            series.append(UsageSeriesPoint(start: max(window.start, slot), end: min(next, window.endExclusive, now),
                                          amount: amount))
            peakTokens = max(peakTokens, amount.totalTokens)
            peakCost = max(peakCost, amount.cost)
            slot = next
        }
    }

    func ranking(_ dimension: UsageRanking.Dimension, by metric: MetricMode) -> UsageRanking {
        guard let pair = rankings[dimension] else { return .empty }
        return metric == .cost ? pair.cost : pair.tokens
    }
}

private struct UsagePlotWindow {
    let start: Date
    let endExclusive: Date
    let calendar: Calendar
    let range: TimeRange

    init?(_ range: TimeRange, customDays: ClosedRange<Date>?, now: Date, calendar: Calendar) {
        self.range = range
        self.calendar = calendar
        let today = calendar.startOfDay(for: now)
        let lastDay: Date
        switch range {
        case .oneDay:
            start = now.addingTimeInterval(-24 * 3600)
            lastDay = today
        case .custom:
            guard let customDays else { return nil }
            start = calendar.startOfDay(for: customDays.lowerBound)
            lastDay = calendar.startOfDay(for: customDays.upperBound)
        default:
            start = calendar.startOfDay(offsetBy: 1 - range.fixedDayCount, from: today)
            lastDay = today
        }
        endExclusive = calendar.startOfDay(offsetBy: 1, from: lastDay)
    }

    func slot(containing date: Date) -> Date {
        if range.isHourly { return Self.utcHour(containing: date) }
        let day = calendar.startOfDay(for: date)
        guard range == .ninetyDays else { return day }
        let weekday = calendar.component(.weekday, from: day)
        let anchor = calendar.component(.weekday, from: start)
        let daysIntoWeek = (weekday - anchor + 7) % 7
        return calendar.startOfDay(offsetBy: -daysIntoWeek, from: day)
    }

    func nextSlot(after date: Date) -> Date {
        if range.isHourly { return date.addingTimeInterval(3600) }
        return calendar.startOfDay(offsetBy: range == .ninetyDays ? 7 : 1, from: date)
    }

    static func utcHour(containing date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3600) * 3600)
    }
}

private extension Calendar {
    /// A DST transition can move one day's start to 01:00. Find each day's actual start.
    func startOfDay(offsetBy days: Int, from date: Date) -> Date {
        startOfDay(for: self.date(byAdding: .day, value: days, to: date)!)
    }
}
