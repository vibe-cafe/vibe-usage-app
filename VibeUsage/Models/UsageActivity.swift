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
    var summaryHelp: String { summaryHelp(duration: ActivityTime.duration) }

    /// The same line with the new panel's duration format.
    func summaryHelp(duration: (Int) -> String) -> String {
        [summary.flatMap { $0.workSeconds > 0 ? "AI 工时 \(duration($0.workSeconds))" : nil },
         summary?.parallelText, coverageHint]
            .compactMap { $0 }.joined(separator: " · ")
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

    init(_ response: UsageActivity, rangeStart: Date, hourly: Bool, timeZone: TimeZone = .current) {
        func key(_ iso: String) -> String {
            hourly ? String(iso.prefix(13)) : Formatters.localDayKey(iso, timeZone: timeZone)
        }
        isHourly = hourly
        firstKey = response.firstBucketStart.map(key)
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
    }

    func time(in key: String) -> ActivityTime? {
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
