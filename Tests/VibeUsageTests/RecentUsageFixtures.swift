import Foundation
@testable import VibeUsage

/// Fixed usage for the 近期消耗 renders (design 134): figures shaped like the
/// design's curves, on a clock fixed at 15:42 today, for every range the
/// panel can ask for. Three tools, two machines, models in three families.
/// Nothing here is real data.
enum RecentUsageFixtures {
    /// Today at 15:42, local time.
    static var now: Date {
        Calendar.current.date(bySettingHour: 15, minute: 42, second: 0, of: Date())!
    }

    /// The custom range drawn in 134h/134i: sixteen days ending nine days ago.
    static var customRange: (from: Date, to: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (calendar.date(byAdding: .day, value: -24, to: today)!,
                calendar.date(byAdding: .day, value: -9, to: today)!)
    }

    static let names = UsageNames(
        sources: ["codex": "Codex", "claude-code": "Claude Code", "cursor": "Cursor"],
        models: ["gpt-5.5": "GPT-5.5", "claude-opus-5-5": "Opus 5.5", "claude-sonnet-5-5": "Sonnet 5.5",
                 "claude-haiku-5-5": "Haiku 5.5", "gemini-3.8-pro": "Gemini 3.8 Pro"],
        modelFamilies: ["gpt-5.5": "gpt", "claude-opus-5-5": "claude", "claude-sonnet-5-5": "claude",
                        "claude-haiku-5-5": "claude", "gemini-3.8-pro": "gemini"],
        families: [UsageFamily(key: "claude", label: "Claude", provider: "anthropic"),
                   UsageFamily(key: "gpt", label: "GPT", provider: "openai"),
                   UsageFamily(key: "gemini", label: "Gemini", provider: "google")]
    )

    /// How one slot's spend splits over tool, model and machine.
    private static let shares: [(source: String, model: String, host: String, share: Double)] = [
        ("codex", "gpt-5.5", "Hogans-MacBook-Pro", 0.40),
        ("codex", "gpt-5.5", "mac-mini", 0.15),
        ("claude-code", "claude-opus-5-5", "Hogans-MacBook-Pro", 0.22),
        ("claude-code", "claude-sonnet-5-5", "Hogans-MacBook-Pro", 0.09),
        ("claude-code", "claude-haiku-5-5", "mac-mini", 0.04),
        ("cursor", "gemini-3.8-pro", "Hogans-MacBook-Pro", 0.10),
    ]

    private static let todayCost: [Double] = [3.2, 6.6, 6.1, 0.4, 7.6, 9.4, 7.9]  // 9:00 … 15:00
    private static let todayActive: [Int] = [1_500, 2_880, 2_400, 0, 1_800, 2_280, 660]
    /// The rolling day, from yesterday 15:00 to today 15:00.
    private static let dayCost: [Double] = [0.6, 1.9, 1.4, 0.7, 1.8, 2.4, 2.9, 1.1, 0.2,
                                            0, 0, 0, 0, 0, 0, 0, 0, 0.3, 5.6, 6.8, 0.9, 0.1, 0.4, 9.4, 8.0]
    private static let weekCost: [Double] = [38, 58, 62, 22, 9, 60, 19]

    /// Spend per slot start for a range; days and weeks use one value per day.
    static func costs(for range: UsageQueryRange) -> [(start: Date, cost: Double)] {
        let calendar = Calendar.current
        let now = now
        let today = calendar.startOfDay(for: now)
        func hour(_ offset: Int, from base: Date) -> Date { base.addingTimeInterval(Double(offset) * 3_600) }
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        switch range {
        case .from:
            let nine = hour(9, from: today)
            return todayCost.enumerated().map { (hour($0.offset, from: nine), $0.element) }
        case .days(1):
            let start = calendar.dateInterval(of: .hour, for: now.addingTimeInterval(-86_400))!.start
            return dayCost.enumerated().map { (hour($0.offset, from: start), $0.element) }
        case .days(7):
            return weekCost.enumerated().map { (day($0.offset - 6), $0.element) }
        case .days(let count):
            return (0..<count).map { index in
                let wave = 34 + 22 * sin(Double(index) / 2.3) + 12 * sin(Double(index) / 0.9)
                return (day(index - count + 1), max(0, wave.rounded()))
            }
        case .custom(let days, _):
            let pattern: [Double] = [8, 44, 52, 41, 47, 30, 6, 4, 49, 55, 38, 46, 33, 8, 5, 47, 57]
            var result: [(Date, Double)] = []
            var cursor = days.start
            var index = 0
            while cursor < days.end {
                result.append((cursor, pattern[index % pattern.count]))
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
                index += 1
            }
            return result
        }
    }

    static func response(for range: UsageQueryRange, empty: Bool) -> UsageResponse {
        guard !empty else { return UsageResponse(buckets: [], sessions: nil, hasAnyData: true, names: names) }
        var buckets: [UsageBucket] = []
        for (start, cost) in costs(for: range) where cost > 0 {
            let stamp = start.formatted(.iso8601)
            for part in shares {
                let spend = cost * part.share
                let total = Int(spend * 1_590_000)
                let cached = Int(Double(total) * 0.954)
                let input = Int(Double(total) * 0.032)
                let output = total - cached - input
                buckets.append(UsageBucket(
                    source: part.source, model: part.model, project: "vibe-usage", hostname: part.host,
                    bucketStart: stamp, inputTokens: input, outputTokens: output,
                    cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, cachedInputTokens: cached,
                    reasoningOutputTokens: 0, totalTokens: total, estimatedCost: spend
                ))
            }
        }
        return UsageResponse(buckets: buckets, sessions: nil, hasAnyData: true, names: names)
    }

    /// Server-side active time: explicit for today, about four minutes per
    /// dollar elsewhere, AI work time 1.4× that. Recorded since long before.
    static func activity(for range: UsageQueryRange, empty: Bool) -> UsageActivity {
        let first = Calendar.current.date(byAdding: .day, value: -200, to: now)!.formatted(.iso8601)
        guard !empty else {
            return UsageActivity(activeSeconds: 0, workSeconds: 0, parallel: nil, series: [], firstBucketStart: first)
        }
        let slots = costs(for: range)
        var series: [UsageActivity.Period] = []
        for (index, slot) in slots.enumerated() {
            let active: Int
            if case .from = range {
                active = todayActive[index]
            } else if range.isHourly {
                active = min(3_600, Int(slot.cost * 300))
            } else {
                active = Int(slot.cost * 256)
            }
            guard active > 0 else { continue }
            series.append(.init(periodStart: slot.start.formatted(.iso8601), activeSeconds: active,
                                workSeconds: Int(Double(active) * 1.4)))
        }
        let active = series.reduce(0) { $0 + $1.activeSeconds }
        let work = series.reduce(0) { $0 + $1.workSeconds }
        return UsageActivity(activeSeconds: active, workSeconds: work,
                             parallel: active > 0 ? 1.4 : nil, series: series, firstBucketStart: first)
    }
}
