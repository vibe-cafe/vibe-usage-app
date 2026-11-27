import Foundation

/// Server-side union of model output time across the selected tools, projects and devices.
struct UsageActivity: Decodable, Sendable {
    struct Period: Decodable, Sendable {
        let periodStart: String
        let activeSeconds: Int
        let workSeconds: Int
    }

    let activeSeconds: Int
    let workSeconds: Int
    let parallel: Double?
    let series: [Period]
    let firstBucketStart: String?
    var since: String?
}

struct ActivityTime: Equatable {
    let activeSeconds: Int
    let workSeconds: Int
    let parallel: Double?

    var activeText: String { Self.duration(activeSeconds) }
    var workText: String { "AI 工时 \(Self.duration(workSeconds))" }
    var chartWorkText: String? { workSeconds > 0 ? "AI 工时: \(Self.duration(workSeconds))" : nil }
    var parallelText: String? {
        guard let parallel else { return nil }
        let count = parallel.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...1)))
        return "平均同时 \(count) 个"
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        if hours == 0 { return "\(minutes)m" }
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}

/// Keys match the classic chart: UTC hours or Gregorian days in the viewer's time zone.
struct ActivityReport: Equatable {
    let summary: ActivityTime?
    private let coverageHint: String?
    var summaryHelp: String {
        [summary.flatMap { $0.workSeconds > 0 ? $0.workText : nil }, summary?.parallelText, coverageHint]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The new panel's hover over active time: the same line without the AI
    /// work time, which 近期消耗 shows as a row of its own.
    var panelHelp: String {
        [summary?.parallelText, coverageHint].compactMap { $0 }.joined(separator: " · ")
    }
    private let firstKey: String?
    private var periods: [String: ActivityTime] = [:]
    /// Hour periods (today, 24H) or day periods (every longer range).
    let isHourly: Bool
    /// The new panel's curve (`UsagePlotGrid.sums`): active and work seconds
    /// keyed by each period's start instant.
    private(set) var activeSecondsByStart: [Date: Int] = [:]
    private(set) var workSecondsByStart: [Date: Int] = [:]
    /// The first recorded instant; nil when nothing was recorded. Periods
    /// before it are unknown, later ones without a period were idle.
    let firstRecorded: Date?
    /// An hourly report summed by local day, for the classic chart, which
    /// asks a single custom day by its day key (the new panel reads that day
    /// by the hour, and switching the style does not read again).
    private var hourlyDays: [String: ActivityTime] = [:]
    private let firstDayKey: String?

    init(_ response: UsageActivity, rangeStart: Date, hourly: Bool, timeZone: TimeZone = .current) {
        func key(_ iso: String) -> String {
            hourly ? String(iso.prefix(13)) : Formatters.localDayKey(iso, timeZone: timeZone)
        }
        isHourly = hourly
        firstKey = response.firstBucketStart.map(key)
        firstDayKey = response.firstBucketStart.map { Formatters.localDayKey($0, timeZone: timeZone) }
        let start = response.since.flatMap(Formatters.dateFromISO8601) ?? rangeStart
        let first = response.firstBucketStart.flatMap(Formatters.dateFromISO8601)
        firstRecorded = first
        let partial = first.map { $0 > start } ?? false
        if first == nil || (partial && response.workSeconds == 0) {
            summary = nil
            coverageHint = "更新后显示"
        } else {
            summary = ActivityTime(activeSeconds: response.activeSeconds, workSeconds: response.workSeconds, parallel: response.parallel)
            coverageHint = partial ? response.firstBucketStart.map {
                "\(Formatters.localDayKey($0, timeZone: timeZone)) 之前的记录无法重算"
            } : nil
        }
        for period in response.series {
            let parallel: Double? = period.activeSeconds > 0
                ? max(1, (10 * Double(period.workSeconds) / Double(period.activeSeconds)).rounded() / 10)
                : nil
            periods[key(period.periodStart)] = ActivityTime(activeSeconds: period.activeSeconds,
                                                           workSeconds: period.workSeconds, parallel: parallel)
            if let date = Formatters.dateFromISO8601(period.periodStart) {
                activeSecondsByStart[date, default: 0] += period.activeSeconds
                workSecondsByStart[date, default: 0] += period.workSeconds
            }
        }
        if hourly {
            var days: [String: (active: Int, work: Int)] = [:]
            for period in response.series {
                let day = Formatters.localDayKey(period.periodStart, timeZone: timeZone)
                days[day, default: (0, 0)].active += period.activeSeconds
                days[day, default: (0, 0)].work += period.workSeconds
            }
            hourlyDays = days.mapValues { total in
                let parallel: Double? = total.active > 0
                    ? max(1, (10 * Double(total.work) / Double(total.active)).rounded() / 10)
                    : nil
                return ActivityTime(activeSeconds: total.active, workSeconds: total.work, parallel: parallel)
            }
        }
    }

    func time(in key: String) -> ActivityTime? {
        // A day key ("yyyy-MM-dd") asked of an hourly report: the sum of its hours.
        if isHourly, key.count == 10 {
            guard let firstDayKey, key >= firstDayKey else { return nil }
            return hourlyDays[key] ?? ActivityTime(activeSeconds: 0, workSeconds: 0, parallel: nil)
        }
        guard let firstKey, key >= firstKey else { return nil }
        return periods[key] ?? ActivityTime(activeSeconds: 0, workSeconds: 0, parallel: nil)
    }
}

extension FilterState {
    var activityQueryItems: [URLQueryItem] {
        sources.sorted().map { URLQueryItem(name: "source", value: $0) }
            + projects.sorted().map { URLQueryItem(name: "project", value: $0) }
            + hostnames.sorted().map { URLQueryItem(name: "hostname", value: $0) }
    }
}
