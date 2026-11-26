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
    let grid: UsagePlotGrid
    private(set) var total = UsageAmount()
    private(set) var series: [UsageSeriesPoint] = []
    private(set) var peakTokens = 0
    private(set) var peakCost = 0.0
    private(set) var tokenComposition = UsageRanking.empty
    private var rankings: [UsageRanking.Dimension: (tokens: UsageRanking, cost: UsageRanking)] = [:]

    init(buckets: [UsageBucket], dataRange: UsageQueryRange,
         filters: UsagePanelFilters = .init(), modelName: (String) -> String = { $0 },
         toolName: (String) -> String = { $0 },
         now: Date, calendar: Calendar = .current) {
        var grid = UsagePlotGrid(dataRange: dataRange, now: now, calendar: calendar)
        var amounts: [Date: UsageAmount] = [:]
        var groups: [UsageRanking.Dimension: [String: UsageAmount]] = [:]
        for bucket in buckets {
            let model = modelName(bucket.model)
            guard filters.includes(bucket, modelName: model), let date = bucket.date,
                  let slot = grid.index(for: date) else { continue }
            amounts[grid.slots[slot].start, default: UsageAmount()].add(bucket)
            total.add(bucket)
            let tool = toolName(bucket.source)
            let terminal = bucket.hostname
            groups[.model, default: [:]][model.isEmpty ? "未知" : model, default: .init()].add(bucket)
            groups[.tool, default: [:]][tool.isEmpty ? "未知" : tool, default: .init()].add(bucket)
            groups[.terminal, default: [:]][terminal.isEmpty ? "未知" : terminal, default: .init()].add(bucket)
        }

        grid.trim(toFirstUsage: amounts.keys.min(), dataRange: dataRange)
        self.grid = grid
        guard !grid.slots.isEmpty else { return }
        tokenComposition = UsageRanking(values: ["缓存": Double(total.cached), "输入": Double(total.input),
                                                 "输出": Double(total.output)])
        rankings = groups.mapValues { names in
            (tokens: UsageRanking(values: names.mapValues { Double($0.totalTokens) }),
             cost: UsageRanking(values: names.mapValues(\.cost)))
        }
        for slot in grid.slots {
            let amount = amounts[slot.start] ?? UsageAmount()
            series.append(UsageSeriesPoint(start: slot.start, end: slot.end, amount: amount))
            peakTokens = max(peakTokens, amount.totalTokens)
            peakCost = max(peakCost, amount.cost)
        }
    }

    func ranking(_ dimension: UsageRanking.Dimension, by metric: MetricMode) -> UsageRanking {
        guard let pair = rankings[dimension] else { return .empty }
        return metric == .cost ? pair.cost : pair.tokens
    }
}

/// The same interval boundaries drive every hero, including hourly or daily activity samples.
struct UsagePlotGrid {
    private(set) var slots: [DateInterval] = []
    private let now: Date
    private let endExclusive: Date
    private let firstServerHour: Date

    init(dataRange: UsageQueryRange, now: Date, calendar: Calendar) {
        self.now = now
        let today = calendar.startOfDay(for: now)
        let start: Date
        let lastDay: Date
        let hourly: Bool
        switch dataRange {
        case .from(let from):
            start = from
            lastDay = calendar.startOfDay(for: from)
            hourly = true
        case .days(1):
            start = now.addingTimeInterval(-24 * 3600)
            lastDay = today
            hourly = true
        case .custom(let from, let to):
            start = calendar.startOfDay(for: from)
            lastDay = calendar.startOfDay(for: to)
            hourly = false
        case .days(let count):
            start = calendar.startOfDay(offsetBy: 1 - count, from: today)
            lastDay = today
            hourly = false
        }
        endExclusive = calendar.startOfDay(offsetBy: 1, from: lastDay)
        firstServerHour = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / 3600) * 3600)

        let weekly = !hourly && calendar.startOfDay(offsetBy: 60, from: start) <= lastDay
        // A short *first* week ends on the same weekday as every subsequent week.
        let weekBoundary = calendar.component(.weekday, from: endExclusive)
        let firstWeekDays = (weekBoundary - calendar.component(.weekday, from: start) + 6) % 7 + 1
        var days = weekly ? firstWeekDays : 1
        var cursor = hourly ? firstServerHour : start
        while max(cursor, start) <= now && cursor < endExclusive {
            let next: Date
            if hourly {
                next = cursor.addingTimeInterval(3600)
            } else {
                next = calendar.startOfDay(offsetBy: days, from: cursor)
                days = weekly ? 7 : 1
            }
            slots.append(DateInterval(start: max(start, cursor), end: min(next, endExclusive, now)))
            cursor = next
        }
    }

    fileprivate mutating func trim(toFirstUsage first: Date?, dataRange: UsageQueryRange) {
        guard let first else { slots = []; return }
        if case .from = dataRange { slots.removeAll { $0.start < first } }
    }

    fileprivate func index(for date: Date) -> Int? {
        guard let first = slots.first, date <= now, date < endExclusive else { return nil }
        // A clipped UTC hour is labelled at its original start by the server.
        if date < first.start {
            return date == firstServerHour && first.start.timeIntervalSince(date) < 3600 ? slots.startIndex : nil
        }
        var low = slots.startIndex
        var high = slots.endIndex
        while low + 1 < high {
            let mid = low + (high - low) / 2
            if slots[mid].start <= date { low = mid } else { high = mid }
        }
        return low
    }

    /// One sum per visible slot, in chart order. Missing coverage stays nil, explicit zero stays zero.
    func sums(_ secondsByPeriodStart: [Date: Int]) -> [Int?] {
        var values = [Int?](repeating: nil, count: slots.count)
        for (date, seconds) in secondsByPeriodStart {
            guard let slot = index(for: date) else { continue }
            values[slot] = (values[slot] ?? 0) + seconds
        }
        return values
    }
}

private extension Calendar {
    /// A DST transition can move one day's start to 01:00. Find each day's actual start.
    func startOfDay(offsetBy days: Int, from date: Date) -> Date {
        startOfDay(for: self.date(byAdding: .day, value: days, to: date)!)
    }
}
