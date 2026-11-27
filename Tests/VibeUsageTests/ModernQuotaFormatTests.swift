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

    @Test func labelColumnWidensOnlyForNamedAllowances() {
        #expect(ModernQuotaFormat.labelColumnWidth(["5h", "7d"]) == 28)
        #expect(ModernQuotaFormat.labelColumnWidth(["5h", "7d", "Fable"]) == 40)
        #expect(ModernQuotaFormat.labelColumnWidth(["5h", "额外"]) == 29)
    }
}
