import Foundation
import Testing
@testable import VibeUsage

struct QuotaPanelDisplayTests {
    typealias Provider = ProviderRateLimit.Provider

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hours: TimeInterval = 3_600

    private func window(_ remaining: Double, _ duration: TimeInterval, due expected: Double) -> RateLimitWindow {
        RateLimitWindow(utilization: 100 - remaining, resetsAt: now.addingTimeInterval(duration * expected / 100),
                        windowDuration: duration)
    }

    private func snapshot(_ provider: Provider, _ short: RateLimitWindow?, _ long: RateLimitWindow?) -> ProviderRateLimit {
        ProviderRateLimit(provider: provider, fiveHour: short, sevenDay: long, status: .ok, fetchedAt: now)
    }

    private var fixtures: [ProviderRateLimit] {
        [
            snapshot(.codex, window(12, 5 * hours, due: 29), window(79, 168 * hours, due: 53)),
            snapshot(.claudeCode, window(36, 5 * hours, due: 16), window(31, 168 * hours, due: 39)),
            ProviderRateLimit(provider: .cursor, meters: [
                .init(id: "plan", label: "Month", window: window(41, 720 * hours, due: 42))
            ], status: .ok),
            snapshot(.antigravity, window(9, 5 * hours, due: 22), window(70, 168 * hours, due: 62)),
            snapshot(.kimiCode, window(71, 5 * hours, due: 34), window(40, 168 * hours, due: 52)),
            snapshot(.grok, nil, window(88, 168 * hours, due: 71)),
            snapshot(.opencodeGo, window(64, 5 * hours, due: 16), window(48, 168 * hours, due: 42)),
            snapshot(.zCode, nil, window(72, 168 * hours, due: 67)),
        ]
    }

    @Test func fiveSubscriptionsAsIn132c() {
        let order: [Provider] = [.cursor, .codex, .claudeCode, .kimiCode, .grok]
        let normalKimi = snapshot(.kimiCode, window(71, 5 * hours, due: 34), window(60, 168 * hours, due: 52))
        let panel = QuotaPanelDisplay(snapshots: fixtures.filter { $0.provider != .kimiCode } + [normalKimi],
                                     enabled: order, selected: nil, now: now)
        #expect(panel.buttons.map(\.provider) == order)
        #expect(panel.overview.rows.map(\.provider) == [.codex, .claudeCode, .cursor])
        #expect(panel.overview.rows.map(\.comment) == ["超额 17%", "超额 8%", "进度正常"])
        #expect(panel.overview.total == 5)
        #expect(panel.overview.nearlyEmpty == 1)
        #expect(panel.overview.fast == 1)
        #expect(panel.overview.tone == .red)
        #expect(panel.overview.remainder?.providers == [.kimiCode, .grok])
        #expect(panel.overview.remainder?.summary == "都正常")
        #expect(panel.overview.remainder?.tone == .neutral)
    }

    @Test func eightSubscriptionsAsIn132d() {
        let order: [Provider] = [.cursor, .kimiCode, .codex, .antigravity, .grok, .claudeCode, .opencodeGo, .zCode]
        let panel = QuotaPanelDisplay(snapshots: fixtures, enabled: order, selected: nil, now: now)
        #expect(panel.buttons.map(\.provider) == order)
        #expect(panel.overview.rows.map(\.provider) == [.codex, .antigravity, .kimiCode])
        #expect(panel.overview.rows.map(\.comment) == ["超额 17%", "超额 13%", "超额 12%"])
        #expect(panel.overview.attentionCount == 4)
        #expect(panel.overview.total == 8)
        #expect(panel.overview.nearlyEmpty == 2)
        #expect(panel.overview.fast == 2)
        #expect(panel.overview.remainder?.providers == [.claudeCode, .cursor, .grok, .opencodeGo, .zCode])
        #expect(panel.overview.remainder?.summary == "1 个超额")
        #expect(panel.overview.remainder?.tone == .amber)
    }

    private func panel(_ snapshot: ProviderRateLimit, models: [RateLimitMeter] = []) -> QuotaPanelDisplay {
        QuotaPanelDisplay(snapshots: [snapshot], enabled: [snapshot.provider], selected: nil, now: now,
                         modelMeters: [snapshot.provider: models])
    }

    @Test func paceBoundariesAndForecastsUseUnroundedPercentages() throws {
        typealias Example = (remaining: Double, duration: Double, expected: Double,
                             tone: QuotaPaceTone, comment: String?, prediction: QuotaPanelMeter.Prediction?)
        let examples: [Example] = [
            (45, 20, 50, .neutral, "进度正常", .runsOutIn(45 * 10 * hours / 55)),
            (55, 20, 50, .neutral, "进度正常", .untilReset),
            (44.9, 20, 50, .amber, "超额 5%", .runsOutIn(44.9 * 10 * hours / 55.1)),
            (56, 20, 50, .neutral, "余量 6%", .untilReset),
            (9, 20, 86, .red, "超额 77%", nil),
            (10, 20, 86, .neutral, nil, nil),
            (9, 20, 85, .red, "超额 76%", .runsOutIn(9 * 3 * hours / 91)),
            (10, 100, 85, .amber, "超额 75%", .runsOutIn(10 * 15 * hours / 90)),
            (10, 100, 50, .amber, "超额 40%", .runsOutIn(10 * 50 * hours / 90)),
            (20, 6, 100.0 / 3, .red, "超额 13%", .runsOutIn(hours)),
            (49, 2, 50, .neutral, "进度正常", .runsOutIn(49 * hours / 51)),
            (19, 5, 20, .neutral, "进度正常", .runsOutIn(19 * 4 * hours / 81)),
            (9, 100, 10, .red, "超额 1%", .runsOutIn(9 * 90 * hours / 91)),
            (9, 168, 9.2, .red, "超额 1%", .runsOutIn(9 * 168 * 0.908 * hours / 91)),
            (7, 8, 25.0 / 480 * 100, .neutral, "进度正常", .untilReset),
            (7, 5, 7, .neutral, "进度正常", .untilReset),
            (6.8, 5, 6.8, .neutral, "进度正常", .untilReset),
            (15.8, 100, 20.8, .neutral, "进度正常", .runsOutIn(15.8 * 79.2 * hours / 84.2)),
            (0, 20, 99, .red, "已用完", nil),
            (100, 20, 50, .neutral, "余量 50%", .untilReset),
        ]
        for example in examples {
            let result = panel(snapshot(.codex, window(example.remaining, example.duration * hours, due: example.expected), nil))
            let row = try #require(result.detail?.rows.first)
            #expect(result.overview.tone == example.tone)
            #expect(row.tone == example.tone)
            #expect(result.detail?.comment == example.comment)
            #expect(result.detail?.commentTone == (example.comment == nil ? .neutral : example.tone))
            if case let (.runsOutIn(actual)?, .runsOutIn(expected)?) = (row.prediction, example.prediction) {
                #expect(abs(actual - expected) < 0.001)
            } else {
                #expect(row.prediction == example.prediction)
            }
        }
    }

    @Test func bothForecastAlertsRequireAtLeastFifteenMinutesBeforeReset() throws {
        // At 80% used the ETA is 57 minutes. At 92% used it is nearly four hours,
        // so only the low-remainder rule can raise the second alert.
        for (used, duration) in [(80.0, 5 * hours), (92.0, 50 * hours)] {
            let elapsedAtCutoff = (duration - 900) * used / 100
            for offset in [-1.0, 0.0, 1.0] {
                let left = duration - elapsedAtCutoff + offset
                let meter = RateLimitWindow(utilization: used, resetsAt: now.addingTimeInterval(left), windowDuration: duration)
                let row = try #require(panel(snapshot(.codex, meter, nil)).detail?.outer)
                #expect(row.tone == (offset < 0 ? .neutral : .red))
                guard case .runsOutIn(let eta) = row.prediction else {
                    Issue.record("Expected an exhaustion forecast even inside the alert margin")
                    continue
                }
                #expect(eta < left)
            }
        }
    }

    @Test func unavailableTimingAndResetNeverInventAPrediction() throws {
        let quota = ProviderRateLimit(provider: .kimiCode, meters: [
            .init(id: "daily", label: "Daily", window: .init(utilization: 99, resetsAt: now.addingTimeInterval(hours))),
            .init(id: "weekly", label: "Weekly", window: .init(utilization: 90, windowDuration: 168 * hours)),
            .init(id: "old", label: "Model A", window: .init(utilization: 100, resetsAt: now)),
        ], status: .ok)
        let detail = try #require(panel(quota).detail)
        #expect(detail.tone == .red)
        #expect(detail.tightest?.label == "1d")
        #expect(detail.buttonRemaining == 1)
        #expect(detail.comment == nil)
        #expect(detail.rows.allSatisfy { $0.prediction == nil && $0.expectedRemaining == nil })
        let daily = try #require(detail.rows.first { $0.id == "daily" })
        #expect(daily.windowDuration == nil && daily.elapsed == nil)
        #expect(daily.timeUntilReset == hours && daily.usedPercent == 99)
        let weekly = try #require(detail.rows.first { $0.id == "weekly" })
        #expect(weekly.windowDuration == 168 * hours && weekly.elapsed == nil)
        #expect(weekly.timeUntilReset == nil && weekly.tone == .neutral)
        #expect(detail.rows.last?.remaining == nil)
        #expect(detail.rows.last?.message == "已重置，等下次读取")
        let exhausted = try #require(panel(snapshot(.codex, .init(utilization: 100), nil)).detail)
        #expect(exhausted.outer?.windowDuration == nil && exhausted.outer?.prediction == nil)
        #expect(exhausted.comment == "已用完" && exhausted.commentTone == .red && exhausted.buttonStatus == "已用完")
        let noReset = panel(snapshot(.codex, .init(utilization: 91, windowDuration: 5 * hours), nil))
        #expect(noReset.detail?.tone == .red && noReset.detail?.comment == nil)
    }

    @Test func exhaustedModelOverridesThePaceCommentAndButtonEvenWithoutDuration() throws {
        let primary = snapshot(.claudeCode, window(12, 5 * hours, due: 29), nil)
        for duration: TimeInterval? in [168 * hours, nil] {
            let model = RateLimitMeter(id: "fable", label: "Fable", window: .init(
                utilization: 100, resetsAt: now.addingTimeInterval(hours), windowDuration: duration))
            let display = QuotaPanelDisplay(snapshots: [primary], enabled: [.claudeCode, .codex],
                                           selected: nil, now: now, modelMeters: [.claudeCode: [model]])
            let row = try #require(display.overview.rows.first)
            #expect(row.comment == "已用完" && row.commentTone == .red)
            #expect(display.buttons.first?.buttonStatus == "已用完" && row.buttonRemaining == 0)
            #expect(display.overview.nearlyEmpty == 1)
        }
    }

    @Test func hiddenFableGetsTheAlertWhenWeeklyIsEquallyUrgentButFurtherBehind() throws {
        var quota = snapshot(.claudeCode, window(50, 5 * hours, due: 50), window(8, 168 * hours, due: 50))
        quota.sevenDayOpus = window(6, 168 * hours, due: 35)
        let fable = RateLimitMeter(id: "fable", label: "Fable", window: window(3, 168 * hours, due: 10))
        let display = panel(quota, models: [fable])
        let row = try #require(display.overview.rows.first)
        #expect(row.outer?.tone == .red && row.outer?.label == "7d")
        #expect(row.additionalAlert?.label == "Fable" && row.additionalAlert?.remaining == 3)
        #expect(row.additionalAlert?.tone == .red && row.comment == "超额 42%")
        #expect(row.buttonRemaining == 3 && display.overview.nearlyEmpty == 1)
    }

    @Test func multipleModelAllowancesUseTheirOwnTimingAndStaySeparateFromTheMainRings() throws {
        var quota = snapshot(.claudeCode, window(36, 5 * hours, due: 16), window(53, 168 * hours, due: 39))
        quota.sevenDayOpus = window(4, 168 * hours, due: 14)
        quota.sevenDaySonnet = window(33, 168 * hours, due: 31)
        quota.extraUsage = .init(isEnabled: true, spend: 100, limit: 100)
        quota.resetCreditsCount = 2
        quota.planLabel = "Max"
        let scoped = [
            RateLimitMeter(id: "scoped-A", label: "Model A", window: window(9, 168 * hours, due: 61)),
            RateLimitMeter(id: "scoped-B", label: "Model B", window: .init(utilization: 98)),
        ]
        let detail = try #require(panel(quota, models: scoped).detail)
        #expect(detail.planLabel == "Max")
        #expect(detail.resetCreditsCount == 2)
        #expect(detail.tone == .red)
        #expect(detail.tightest?.label == "Model B")
        #expect(detail.buttonRemaining == 2)
        #expect(detail.comment == "超额 52%")
        #expect(detail.additionalAlert?.label == "Model A")
        #expect(detail.additionalAlert?.remaining == 9)
        #expect(detail.additionalAlert?.tone == .red)
        #expect(detail.outer?.label == "7d" && detail.outer?.expectedRemaining == 39)
        #expect(detail.inner?.label == "5h" && detail.inner?.expectedRemaining == 16)
        #expect(detail.rows.map(\.label) == ["5h", "7d", "Model A", "Model B", "Opus", "Sonnet", "额外"])
        #expect(detail.compactRows.map(\.label) == ["5h", "7d", "Model B"])
        #expect(detail.foldedCount == 4)
        #expect(detail.rows.last?.remaining == 0 && detail.rows.last?.tone == .neutral)
    }

    @Test func calendarMonthCanBeTightestAndPayAsYouGoNeverOwnsARing() throws {
        let month = RateLimitMeter(id: "monthly", label: "Monthly", window: .init(utilization: 78))
        let extra = RateLimitMeter(id: "on-demand", label: "On-demand", window: .init(utilization: 100))
        let short = RateLimitMeter(id: "rolling", label: "5h", window: window(64, 5 * hours, due: 16))
        let long = RateLimitMeter(id: "weekly", label: "Weekly", window: window(48, 168 * hours, due: 39))
        var quota = ProviderRateLimit(provider: .opencodeGo, meters: [month, long, short], status: .ok)
        let detail = try #require(panel(quota).detail)
        #expect(detail.tightest?.remaining == 22 && detail.tightest?.label == "mo")
        #expect(detail.rows.map(\.label) == ["5h", "7d", "mo"])
        #expect(detail.outer?.label == "7d" && detail.inner?.label == "5h")
        #expect(detail.rows.last?.prediction == nil)
        quota = ProviderRateLimit(provider: .cursor, meters: [extra, month], status: .ok)
        let single = try #require(panel(quota).detail)
        #expect(single.outer?.label == "mo" && single.inner == nil)
        #expect(single.tone == .neutral && single.buttonRemaining == 22)
        #expect(single.rows.map(\.label) == ["mo", "额外"])
    }

    @Test func countSelectionAndRefreshScopeFollowOnlyEnabledSubscriptions() {
        func display(_ enabled: [Provider], selecting selected: Provider? = nil) -> QuotaPanelDisplay {
            QuotaPanelDisplay(snapshots: fixtures, enabled: enabled, selected: selected, now: now)
        }
        let empty = display([], selecting: .codex)
        #expect(empty.isEmpty && empty.buttons.isEmpty && empty.detail == nil)
        #expect(empty.refreshTargets.isEmpty)
        let single = display([.grok], selecting: .grok)
        #expect(single.buttons.isEmpty && single.detail?.provider == .grok)
        #expect(single.usageProvider == nil && single.refreshTargets == [.grok])
        let order: [Provider] = [.grok, .claudeCode, .cursor, .codex]
        let overview = display(order, selecting: .zCode)
        #expect(overview.detail == nil && overview.usageProvider == nil)
        #expect(overview.overview.rows.map(\.provider) == [.codex, .claudeCode, .grok, .cursor])
        #expect(overview.overview.remainder == nil && overview.buttons.map(\.provider) == order)
        #expect(display([.grok, .codex]).overview.rows.map(\.provider) == [.codex, .grok])
        #expect(overview.refreshTargets == order)
        let selected = display(order, selecting: .cursor)
        #expect(selected.detail?.provider == .cursor && selected.usageProvider == .cursor)
        #expect(selected.refreshTargets == [.cursor])
    }

    @Test func exhaustedWithoutAWindowIsOneRedSubscriptionWithNoInventedMeter() throws {
        let empty = ProviderRateLimit(provider: .codex, status: .noData, fetchedAt: now, emptyReason: .limitReached)
        let result = QuotaPanelDisplay(snapshots: [empty], enabled: [.codex, .cursor], selected: .codex, now: now)
        let card = try #require(result.detail)
        #expect(result.overview.attentionCount == 1 && result.overview.tone == .red)
        #expect(card.tone == .red && card.comment == "已用完" && card.buttonRemaining == 0)
        #expect(card.commentTone == .red && card.buttonStatus == "已用完")
        #expect(card.rows.isEmpty && card.tightest == nil && card.outer == nil && card.inner == nil)
        #expect(card.detailTitle == "已用完" && !card.showsWhiteDot)
    }

    @Test func coldReadsShowSkeletonsAndWarmRefreshesKeepTheirNumbers() throws {
        let order: [Provider] = [.cursor, .codex]
        let display = QuotaPanelDisplay(snapshots: [fixtures[0]], enabled: order, selected: .cursor, now: now,
                                       refreshing: Set(order))
        let cold = try #require(display.detail)
        #expect(cold.showsSkeleton && cold.detailTitle == "正在读取…" && cold.buttonRemaining == nil)
        #expect(cold.readState == .loading && cold.comment == nil)
        #expect(!cold.showsWhiteDot && cold.action == nil)
        let warm = try #require(display.buttons.last)
        #expect(warm.readState == .normal && !warm.showsSkeleton && warm.buttonRemaining == 12)
        #expect(display.isRefreshing)
    }

    @Test func emptyStatesSupplyReasonDotAndOnlyTheApplicableAction() throws {
        typealias Example = (Provider, ProviderRateLimit.Status, ProviderRateLimit.EmptyReason?,
                             ProviderRateLimit.LiveFailure?, QuotaSubscriptionDisplay.ReadState,
                             String, String, Bool, QuotaSubscriptionDisplay.Action?)
        let examples: [Example] = [
            (.cursor, .noData, nil, .signInRequired, .needsLogin, "需登录", "需要登录 Cursor", true, .cursorSettings),
            (.cursor, .noData, nil, .signInExpired, .loginExpired, "登录已失效", "Cursor 登录已失效", true, .cursorSettings),
            (.claudeCode, .unauthorized, nil, .credentialsRejected, .loginExpired, "登录已失效", "登录已失效，请重新登录", true, .retry),
            (.kimiCode, .unauthorized, nil, .credentialsNotFound, .needsLogin, "需登录", "请先登录 Kimi Code", true, .retry),
            (.zCode, .unauthorized, nil, .credentialsRejected, .loginExpired, "Key 无效", "API Key 无效，请在设置中更换", true, .retry),
            (.antigravity, .unauthorized, nil, .credentialsRejected, .needsLogin, "需登录", "请在 Antigravity 中登录", true, .retry),
            (.opencodeGo, .noData, nil, .credentialsExpired, .loginExpired, "登录已失效", "打开 OpenCode 后自动显示", true, nil),
            (.grok, .retryableError, nil, .endpointTimedOut, .readFailed, "读取失败", "暂时读不到额度", true, .retry),
            (.codex, .error("raw"), nil, nil, .readFailed, "读取失败", "暂时读不到额度", true, .retry),
            (.claudeCode, .noData, .nonessentialTrafficDisabled, nil, .organizationPolicy, "组织策略",
             "组织策略关闭了 Claude Code 非必要流量 · 无法读取", true, nil),
            (.claudeCode, .noData, .sessionWithoutPlanLimits, nil, .nonSubscriptionLogin,
             "未使用订阅登录", "Claude Code 未使用订阅登录", false, nil),
            (.codex, .noData, .noWindow, nil, .normal, "无窗口", "没有生效的额度窗口", false, nil),
        ]
        for (provider, status, empty, failure, state, overview, detail, dot, action) in examples {
            let quota = ProviderRateLimit(provider: provider, status: status, fetchedAt: now,
                                          emptyReason: empty, liveFailure: failure)
            let card = try #require(panel(quota).detail)
            #expect(card.comment == overview && card.detailTitle == detail)
            #expect(card.readState == state && card.commentTone == .neutral && card.buttonStatus == overview)
            #expect(card.detailReason == (failure == .endpointTimedOut ? "读取超时" : nil))
            #expect(card.showsWhiteDot == dot && card.action == action)
            #expect(card.outer == nil && card.buttonRemaining == nil && card.tone == .neutral)
        }
    }

    @Test func everyNetworkPauseKeepsAvailableMetersAndExplainsItsRoute() throws {
        let pauses: [(ProviderRateLimit.LiveFailure, String)] = [
            (.egressRegionUnsupported("CN"), "网络出口在中国大陆，已暂停读取"),
            (.egressUnconfirmed, "无法确认网络出口，已暂停读取"),
            (.proxyNotDetected, "未检测到代理，已暂停读取"),
            (.proxyUnsupported, "代理无法照着走，已暂停读取"),
        ]
        for (failure, reason) in pauses {
            var quota = ProviderRateLimit(provider: .codex, status: .noData, fetchedAt: now, liveFailure: failure)
            let empty = try #require(panel(quota).detail)
            #expect(empty.comment == "已暂停读取" && empty.detailTitle == reason)
            #expect(empty.readState == .paused && empty.commentTone == .neutral)
            #expect(empty.buttonRemaining == nil && empty.showsWhiteDot && empty.action == nil)
            quota.status = .ok
            quota.source = .cache
            for (remaining, tone): (Double, QuotaPaceTone) in [(36, .amber), (0, .red)] {
                quota.sevenDay = window(remaining, 168 * hours, due: 48)
                let kept = try #require(panel(quota).detail)
                #expect(kept.buttonRemaining == remaining && kept.tone == tone && kept.showsWhiteDot)
                #expect(kept.readState == .paused && kept.commentTone == .neutral)
                #expect(kept.buttonStatus == "读取已暂停" && kept.comment == "已暂停读取")
                #expect(kept.sourceNote == "来源：缓存 · \(reason)" && kept.detailTitle == nil && kept.action == nil)
            }
        }
    }

    @Test func nonLiveReadNamesOnlyItsKnownSourceAndReason() throws {
        let sources: [(ProviderRateLimit.Source, String)] = [
            (.localLog, "本地日志"), (.desktopRecord, "Claude 桌面端记录"), (.cache, "缓存"), (.live, "上次实时读取"),
        ]
        for (source, label) in sources {
            var quota = fixtures[0]
            quota.source = source
            #expect(panel(quota).detail?.sourceNote == nil)
            quota.liveFailure = .endpointTimedOut
            let kept = try #require(panel(quota).detail)
            #expect(kept.sourceNote == "来源：\(label) · 读取超时")
            #expect(!kept.showsWhiteDot && kept.buttonRemaining == 12)
        }
    }

    @Test func policyKeepsTheDesktopReadingAndExplainsOnlyTheLiveRead() throws {
        var quota = snapshot(.claudeCode, .init(utilization: 28), nil)
        quota.source = .desktopRecord
        quota.liveFailure = .claudeBlockedByPolicy
        let kept = try #require(panel(quota).detail)
        #expect(kept.buttonRemaining == 72 && kept.outer?.remaining == 72 && kept.rows.count == 1)
        #expect(kept.detailTitle == nil && !kept.showsWhiteDot && kept.action == nil)
        #expect(kept.readState == .organizationPolicy && kept.comment == "组织策略")
        #expect(kept.sourceNote == "来源：Claude 桌面端记录 · 组织策略关闭了 Claude Code 非必要流量")
        quota.status = .noData
        let empty = try #require(panel(quota).detail)
        #expect(empty.rows.isEmpty && empty.showsWhiteDot && empty.sourceNote == nil)
        #expect(empty.detailTitle == "组织策略关闭了 Claude Code 非必要流量")
    }

    @Test func hoverUsesTheReportedWindowAndThePanelClock() throws {
        let quota = snapshot(.codex, window(70, 4 * hours, due: 25),
                             .init(utilization: 90, resetsAt: now, windowDuration: 7 * 24 * hours))
        let card = try #require(panel(quota).detail)
        let current = card.rows[0]
        #expect(current.windowDuration == 4 * hours && current.elapsed == 3 * hours)
        #expect(current.usedPercent == 30 && current.timeUntilReset == hours)
        let expired = card.rows[1]
        #expect(expired.windowDuration == 7 * 24 * hours && expired.timeUntilReset == nil)
        #expect(expired.usedPercent == nil && expired.elapsed == nil)
    }

    @Test func mixedWindowsKeepMainRowsFirstAndExpiredReadingsExplainThemselves() throws {
        let quota = ProviderRateLimit(provider: .opencodeGo, meters: [
            .init(id: "monthly", label: "Monthly", window: .init(utilization: 30)),
            .init(id: "short", label: "1h", window: window(100, hours, due: 50)),
            .init(id: "long", label: "Weekly", window: window(31, 168 * hours, due: 39)),
            .init(id: "session", label: "5h", window: window(36, 5 * hours, due: 16)),
            .init(id: "group", label: "Model group", window: .init(utilization: 3)),
        ], status: .ok)
        let detail = try #require(panel(quota).detail)
        #expect(detail.rows.map(\.label) == ["5h", "7d", "1h", "Model group", "mo"])
        #expect(detail.inner?.label == "5h" && detail.outer?.label == "7d")
        #expect(detail.tightest?.label == "7d" && detail.buttonRemaining == 31)
        let stale = try #require(panel(snapshot(.codex, .init(utilization: 100, resetsAt: now.addingTimeInterval(-1)), nil)).detail)
        #expect(stale.comment == "已重置" && stale.rows.first?.message == "已重置，等下次读取")
        #expect(stale.buttonRemaining == nil && stale.outer == nil && stale.tone == .neutral)
    }

    @Test func aHiddenUnreadableSubscriptionIsNotSummarizedAsHealthy() {
        let order: [Provider] = [.codex, .claudeCode, .cursor, .grok, .opencodeGo]
        let missing = ProviderRateLimit(provider: .opencodeGo, status: .noData, liveFailure: .credentialsNotFound)
        let panel = QuotaPanelDisplay(snapshots: fixtures.filter { $0.provider != .opencodeGo } + [missing],
                                     enabled: order, selected: .opencodeGo, now: now)
        #expect(panel.overview.remainder?.providers == [.grok, .opencodeGo])
        #expect(panel.overview.remainder?.summary == nil && panel.overview.remainder?.tone == .neutral)
        #expect(panel.detail?.showsWhiteDot == true)
        #expect(panel.overview.attentionCount == 2)
    }

    @Test func foldedSummaryCountsRedAndAmberSeparatelyEvenWithAnUnreadableIcon() throws {
        let red: [Provider] = [.codex, .cursor, .kimiCode, .zCode, .opencodeGo]
        let amber = snapshot(.claudeCode, window(45, 168 * hours, due: 60), nil)
        let missing = ProviderRateLimit(provider: .grok, status: .noData, liveFailure: .credentialsNotFound)
        let readings = red.map { snapshot($0, .init(utilization: 99), nil) } + [amber, missing]
        for includeAmber in [false, true] {
            let order = [.grok] + (includeAmber ? [.claudeCode] : []) + red
            let panel = QuotaPanelDisplay(snapshots: readings, enabled: order, selected: nil, now: now)
            let hidden = try #require(panel.overview.remainder)
            #expect(hidden.providers == Array(red.suffix(2)) + (includeAmber ? [.claudeCode] : []) + [.grok])
            #expect(hidden.summary == (includeAmber ? "2 个快用完 · 1 个超额" : "2 个快用完"))
            #expect(hidden.tone == .red && panel.buttons.first?.showsWhiteDot == true)
        }
    }

    @Test func urgencyAndCommentCanComeFromDifferentWindows() throws {
        let quota = snapshot(.claudeCode, window(45, 5 * hours, due: 65), window(72, 168 * hours, due: 60))
        let scoped = RateLimitMeter(id: "model", label: "Model", window: window(8, 168 * hours, due: 9))
        let card = try #require(panel(quota, models: [scoped]).detail)
        #expect(card.tone == .red && card.buttonRemaining == 8)
        #expect(card.additionalAlert?.label == "Model" && card.inner?.tone == .amber)
        #expect(card.comment == "超额 20%")

        let smallLag = snapshot(.claudeCode, window(10.5, 8 * hours, due: 13.5), window(46, 168 * hours, due: 50))
        let red = try #require(panel(smallLag).detail)
        #expect(red.inner?.tone == .red && red.outer?.tone == .neutral)
        #expect(red.tone == .red && red.comment == "超额 4%")

        let early = snapshot(.claudeCode, window(20, 5 * hours, due: 90), window(44, 168 * hours, due: 50))
        let amber = try #require(panel(early).detail)
        #expect(amber.inner?.tone == .neutral && amber.outer?.tone == .amber)
        #expect(amber.tone == .amber && amber.comment == "超额 6%")
    }
}
