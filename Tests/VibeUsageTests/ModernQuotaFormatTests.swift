import Foundation
import Testing
@testable import VibeUsage

/// How the new 订阅配额 card writes numbers and times. The values come from
/// `QuotaPanelDisplay` (tested in `QuotaPanelDisplayTests`); this is only
/// their wording.
struct ModernQuotaFormatTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hours: TimeInterval = 3_600

    @Test func aSliverLeftIsNeverWrittenAsZero() {
        #expect(ModernQuotaFormat.percent(0) == "0")
        #expect(ModernQuotaFormat.percent(0.4) == "<1")
        #expect(ModernQuotaFormat.percent(0.99) == "<1")
        #expect(ModernQuotaFormat.percent(1) == "1")
        #expect(ModernQuotaFormat.percent(12.4) == "12")
        #expect(ModernQuotaFormat.percent(99.6) == "100")
    }

    @Test func onlyTheOverviewRowShortensAntigravity() {
        #expect(ProviderRateLimit.Provider.antigravity.overviewName == "Antigravity")
        #expect(ProviderRateLimit.Provider.antigravity.displayName == "Antigravity / AGY")
        for provider in ProviderRateLimit.Provider.allCases where provider != .antigravity {
            #expect(provider.overviewName == provider.displayName)
        }
    }

    @Test func forecastsReadAsTheDesignWritesThem() {
        #expect(ModernQuotaFormat.prediction(.untilReset) == "够用到重置")
        #expect(ModernQuotaFormat.prediction(.runsOutIn(30 * 60)) == "约 30 分钟后用完")
        #expect(ModernQuotaFormat.prediction(.runsOutIn(20)) == "约 1 分钟后用完")
        #expect(ModernQuotaFormat.prediction(.runsOutIn(3 * hours)) == "约 3 小时后用完")
        #expect(ModernQuotaFormat.prediction(.runsOutIn(23.7 * hours)) == "约 1 天后用完")
        #expect(ModernQuotaFormat.prediction(.runsOutIn(46 * hours)) == "约 2 天后用完")
    }

    @Test func durationsRoundToTheirLastUnit() {
        #expect(ModernQuotaFormat.duration(89 * hours - 60) == "3 天 17 小时")
        #expect(ModernQuotaFormat.duration(3 * 24 * hours) == "3 天")
        #expect(ModernQuotaFormat.duration(2 * hours + 5 * 60 + 20) == "2 小时 5 分钟")
        #expect(ModernQuotaFormat.duration(hours) == "1 小时")
        #expect(ModernQuotaFormat.duration(12 * 60) == "12 分钟")
        #expect(ModernQuotaFormat.duration(5) == "1 分钟")
    }

    private func meter(_ window: RateLimitWindow, label: String = "7d") -> QuotaPanelMeter {
        let snapshot = ProviderRateLimit(provider: .codex, meters: [.init(id: "m", label: label, window: window)],
                                         status: .ok, fetchedAt: now)
        let display = QuotaPanelDisplay(snapshots: [snapshot], enabled: [.codex], selected: nil, now: now)
        return display.detail!.rows[0]
    }

    @Test func resetIsAClockTimeWithinADayAndDaysAfterThat() throws {
        let soon = meter(.init(utilization: 50, resetsAt: now.addingTimeInterval(2 * hours), windowDuration: 5 * hours))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        #expect(ModernQuotaFormat.reset(soon) == formatter.string(from: now.addingTimeInterval(2 * hours)))
        let later = meter(.init(utilization: 50, resetsAt: now.addingTimeInterval(89 * hours), windowDuration: 168 * hours))
        #expect(ModernQuotaFormat.reset(later) == "4天后")
        let unknown = meter(.init(utilization: 50))
        #expect(ModernQuotaFormat.reset(unknown) == nil)
    }

    @Test func tooltipNamesTheWindowAndOnlyWhatIsKnown() throws {
        let weekly = meter(.init(utilization: 21, resetsAt: now.addingTimeInterval(89 * hours), windowDuration: 168 * hours))
        let tooltip = try #require(ModernQuotaFormat.tooltip(for: weekly, provider: .codex))
        #expect(tooltip.title == "7 天窗口")
        #expect(tooltip.lines == [
            .init(label: "已使用", value: "21%"),
            .init(label: "已过去", value: "3 天 7 小时"),
            .init(label: "离重置", value: "3 天 17 小时"),
        ])
        let monthly = meter(.init(utilization: 78), label: "Monthly")
        let plain = try #require(ModernQuotaFormat.tooltip(for: monthly, provider: .opencodeGo))
        #expect(plain.title == "mo" && plain.lines == [.init(label: "已使用", value: "78%")])
        let expired = meter(.init(utilization: 40, resetsAt: now.addingTimeInterval(-60), windowDuration: 168 * hours))
        #expect(ModernQuotaFormat.tooltip(for: expired, provider: .codex) == nil)
    }

    /// The Cursor sample `QuotaCLIBridgeTests` decodes: Month 48% with its
    /// own/third-party split, resetting 2026-11-01.
    private func cursorWithSplit() throws -> ProviderRateLimit {
        let envelope = try QuotaCLIBridge.decode("""
        {"schemaVersion":1,"products":[{"id":"cursor","status":"ok","fetchedAt":"2026-10-23T00:00:00Z","source":"live",
          "meters":[
            {"id":"plan","label":"Month","utilization":48,"resetsAt":"2026-11-01T00:00:00Z","windowSeconds":2678400,
             "breakdown":[{"id":"auto","label":"Cursor models","utilization":4},{"id":"api","label":"Third-party models","utilization":88}]},
            {"id":"on-demand","label":"On-demand","utilization":25}]}]}
        """)
        return try #require(QuotaCLIBridge.snapshots(from: envelope).first)
    }

    @Test func aReadingPastItsResetShowsNoTooltipNotEvenItsSplit() throws {
        let cursor = try cursorWithSplit()
        func month(at instant: String) throws -> QuotaPanelMeter {
            let now = try #require(Formatters.dateFromISO8601(instant))
            let display = QuotaPanelDisplay(snapshots: [cursor], enabled: [.cursor], selected: nil, now: now)
            return try #require(display.detail?.rows.first { $0.id == "plan" })
        }
        let current = try month(at: "2026-10-23T00:00:00Z")
        let lines = try #require(ModernQuotaFormat.tooltip(for: current, provider: .cursor)).lines
        #expect(lines.contains(.init(label: "Cursor 模型", value: "4%")))
        #expect(lines.contains(.init(label: "第三方模型", value: "88%")))
        let expired = try month(at: "2026-11-02T00:00:00Z")
        #expect(expired.message == "已重置，等下次读取")
        #expect(ModernQuotaFormat.tooltip(for: expired, provider: .cursor) == nil)
    }

    private func overviewRow(_ snapshot: ProviderRateLimit, models: [RateLimitMeter] = []) throws -> QuotaSubscriptionDisplay {
        let display = QuotaPanelDisplay(snapshots: [snapshot], enabled: [snapshot.provider, .grok], selected: nil, now: now,
                                       modelMeters: [snapshot.provider: models])
        return try #require(display.overview.rows.first { $0.provider == snapshot.provider })
    }

    private func window(_ remaining: Double, _ duration: TimeInterval, due: Double) -> RateLimitWindow {
        RateLimitWindow(utilization: 100 - remaining, resetsAt: now.addingTimeInterval(duration * due / 100),
                        windowDuration: duration)
    }

    @Test func aLoneAlertingTeamPoolIsWrittenOnce() throws {
        func team(_ remaining: Double) -> ProviderRateLimit {
            ProviderRateLimit(provider: .cursor, meters: [
                .init(id: "team", label: "Team", window: window(remaining, 720 * hours, due: 33)),
            ], status: .ok, fetchedAt: now)
        }
        let alerting = try overviewRow(team(5))
        #expect(alerting.additionalAlert?.id == "team" && alerting.tightest?.id == "team")
        #expect(ModernQuotaFormat.overviewChips(alerting) == [
            .init(id: "team", label: "Team", remaining: 5, tone: .red, isColumn: false),
        ])
        let calm = try overviewRow(team(70))
        #expect(calm.additionalAlert == nil)
        #expect(ModernQuotaFormat.overviewChips(calm) == [
            .init(id: "team", label: "Team", remaining: 70, tone: .neutral, isColumn: false),
        ])
    }

    @Test func overviewChipsPutTheAlertBeforeTheRingWindows() throws {
        let claude = ProviderRateLimit(provider: .claudeCode, fiveHour: window(36, 5 * hours, due: 16),
                                       sevenDay: window(53, 168 * hours, due: 39), status: .ok, fetchedAt: now)
        let fable = RateLimitMeter(id: "fable", label: "Fable", window: window(9, 168 * hours, due: 61))
        let chips = ModernQuotaFormat.overviewChips(try overviewRow(claude, models: [fable]))
        #expect(chips.map(\.label) == ["Fable", "5h", "7d"])
        #expect(chips.map(\.isColumn) == [false, true, true])
        #expect(chips.map(\.tone) == [.red, .neutral, .neutral])
        let weeklyOnly = ProviderRateLimit(provider: .claudeCode, sevenDay: window(62, 168 * hours, due: 55),
                                           status: .ok, fetchedAt: now)
        #expect(ModernQuotaFormat.overviewChips(try overviewRow(weeklyOnly)).map(\.label) == ["7d"])
    }

    @Test func labelColumnWidensOnlyForNamedAllowances() {
        #expect(ModernQuotaFormat.labelColumnWidth(["5h", "7d"]) == 28)
        #expect(ModernQuotaFormat.labelColumnWidth(["5h", "7d", "Fable"]) == 40)
        #expect(ModernQuotaFormat.labelColumnWidth(["5h", "额外"]) == 29)
    }
}
