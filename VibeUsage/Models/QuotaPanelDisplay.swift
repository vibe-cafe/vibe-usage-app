import Foundation

/// A snapshot of the new panel at the supplied instant. Provider order comes from Settings.
struct QuotaPanelDisplay {
    typealias Provider = ProviderRateLimit.Provider

    let buttons: [QuotaSubscriptionDisplay]
    let overview: QuotaOverviewDisplay
    let detail: QuotaSubscriptionDisplay?
    let refreshTargets: [Provider]
    let isRefreshing: Bool
    var isEmpty: Bool { overview.total == 0 }
    var usageProvider: Provider? { buttons.isEmpty ? nil : detail?.provider }

    init(snapshots: [ProviderRateLimit], enabled: [Provider], selected: Provider?, now: Date,
         modelMeters: [Provider: [RateLimitMeter]] = [:], refreshing: Set<Provider> = [],
         detected: Set<Provider> = [], zCodeRegion: ZCodeQuotaRegion = .bigModel) {
        let subscriptions = enabled.map { provider in
            let snapshot = snapshots.first { $0.provider == provider } ?? .init(provider: provider, status: .noData)
            return QuotaSubscriptionDisplay(snapshot: snapshot, modelMeters: modelMeters[provider] ?? [], now: now,
                                           refreshing: refreshing.contains(provider), detected: detected.contains(provider),
                                           zCodeRegion: zCodeRegion)
        }
        buttons = subscriptions.count > 1 ? subscriptions : []
        overview = QuotaOverviewDisplay(subscriptions)
        detail = subscriptions.count == 1 ? subscriptions.first : subscriptions.first { $0.provider == selected }
        refreshTargets = detail.map { [$0.provider] } ?? enabled
        isRefreshing = !refreshing.isDisjoint(with: refreshTargets)
    }
}

enum QuotaPaceTone: Int {
    case neutral, amber, red
}

struct QuotaOverviewDisplay {
    struct Remainder {
        let providers: [ProviderRateLimit.Provider]
        let summary: String?
        let tone: QuotaPaceTone
    }

    let rows: [QuotaSubscriptionDisplay]
    let remainder: Remainder?
    let total: Int
    let nearlyEmpty: Int
    let fast: Int
    var attentionCount: Int { nearlyEmpty + fast }
    var tone: QuotaPaceTone { nearlyEmpty > 0 ? .red : (fast > 0 ? .amber : .neutral) }

    fileprivate init(_ subscriptions: [QuotaSubscriptionDisplay]) {
        total = subscriptions.count
        nearlyEmpty = subscriptions.filter { $0.tone == .red }.count
        fast = subscriptions.filter { $0.tone == .amber }.count
        // Swift's stable sort preserves Settings order within each tone.
        let ordered = subscriptions.sorted { $0.tone.rawValue > $1.tone.rawValue }
        guard total >= 5 else {
            rows = ordered
            remainder = nil
            return
        }
        rows = Array(ordered.prefix(3))
        let hidden = ordered.dropFirst(3)
        let red = hidden.filter { $0.tone == .red }.count
        let amber = hidden.filter { $0.tone == .amber }.count
        var labels: [String] = []
        if red > 0 { labels.append("\(red) 个快用完") }
        if amber > 0 { labels.append("\(amber) 个超额") }
        if labels.isEmpty, hidden.allSatisfy({ !$0.showsWhiteDot && $0.buttonRemaining != nil }) {
            labels.append("都正常")
        }
        remainder = Remainder(providers: hidden.map(\.provider),
                              summary: labels.isEmpty ? nil : labels.joined(separator: " · "),
                              tone: hidden.first?.tone ?? .neutral)
    }
}

struct QuotaSubscriptionDisplay {
    enum Action { case retry, cursorSettings }

    enum ReadState {
        case normal, loading, needsLogin, loginExpired, readFailed, paused, organizationPolicy, nonSubscriptionLogin
    }

    let provider: ProviderRateLimit.Provider
    let planLabel: String?
    let resetCreditsCount: Int?
    let rows: [QuotaPanelMeter]
    let tightest: QuotaPanelMeter?
    let additionalAlert: QuotaPanelMeter?
    let outer: QuotaPanelMeter?
    let inner: QuotaPanelMeter?
    /// The big number in the middle of the rings: the ring window with the
    /// least left. Model allowances (Fable, Opus, Sonnet) and pay-as-you-go
    /// spend never take the middle, even when tightest (maintainer
    /// 2026-11-27); they keep driving the button, the counts and the
    /// overview's extra label. Without any ring window, the tightest.
    var ringCenter: QuotaPanelMeter? {
        let rings = [outer, inner].compactMap { $0 }
        guard !rings.isEmpty else { return tightest }
        return rings.min { ($0.remaining ?? 100) < ($1.remaining ?? 100) }
    }
    let tone: QuotaPaceTone
    let comment: String?
    private let reading: Reading
    let sourceNote: String?
    let buttonRemaining: Double?
    var readState: ReadState { reading.state }
    var commentTone: QuotaPaceTone { readState == .normal && comment != nil ? tone : .neutral }
    var showsSkeleton: Bool { readState == .loading }
    var detailTitle: String? { rows.isEmpty ? reading.title : nil }
    var detailReason: String? { reading.reason }
    var showsWhiteDot: Bool {
        switch readState {
        case .paused, .needsLogin, .loginExpired, .readFailed: true
        case .organizationPolicy: rows.isEmpty
        case .normal, .loading, .nonSubscriptionLogin: false
        }
    }
    var action: Action? { reading.action }
    var buttonStatus: String {
        if readState == .paused { return "读取已暂停" }
        if let label = reading.shortReason(for: provider) { return label }
        if showsSkeleton { return "正在读取…" }
        if buttonRemaining == 0 { return "已用完" }
        switch tone {
        case .red: return "快用完"
        case .amber: return "偏快"
        case .neutral: return tightest == nil ? (comment ?? "暂无订阅配额数据") : "正常"
        }
    }

    var compactRows: [QuotaPanelMeter] {
        let firstThree = Array(rows.prefix(3))
        guard let tightest, !firstThree.contains(tightest) else { return firstThree }
        return Array(firstThree.prefix(2)) + [tightest]
    }
    var foldedCount: Int { max(0, rows.count - 3) }

    fileprivate init(snapshot: ProviderRateLimit, modelMeters: [RateLimitMeter], now: Date,
                     refreshing: Bool, detected: Bool, zCodeRegion: ZCodeQuotaRegion) {
        provider = snapshot.provider
        planLabel = snapshot.planLabel
        resetCreditsCount = snapshot.resetCreditsCount
        reading = Reading.resolve(snapshot, refreshing: refreshing, detected: detected, zCodeRegion: zCodeRegion)
        let reportedExhausted = snapshot.emptyReason == .limitReached && reading.state == .normal
        if snapshot.status == .ok && !reportedExhausted {
            rows = QuotaPanelMeter.rows(snapshot: snapshot, modelMeters: modelMeters, now: now)
        } else {
            rows = []
        }
        sourceNote = rows.isEmpty ? nil : QuotaStatusText.sourceNote(for: snapshot)
        let plan = rows.filter { !$0.isExtra }
        let current = plan.filter { $0.remaining != nil }
        tightest = current.min { ($0.remaining ?? 100) < ($1.remaining ?? 100) }
        buttonRemaining = reportedExhausted ? 0 : tightest?.remaining

        // Only primary windows draw rings. An expired primary must never paint its old reading.
        let rings = current.filter { $0.primarySortDuration != nil }.sorted {
            ($0.primarySortDuration ?? 0) > ($1.primarySortDuration ?? 0)
        }
        outer = rings.first
        inner = rings.dropFirst().first
        let worstTone = current.map(\.tone).max { $0.rawValue < $1.rawValue } ?? .neutral
        tone = reportedExhausted ? .red : worstTone
        // Name the first equally urgent allowance that has no overview bar.
        additionalAlert = worstTone == .neutral ? nil : current.first {
            $0.primarySortDuration == nil && $0.tone == worstTone
        }
        if let reason = reading.shortReason(for: provider) {
            comment = reason
        } else if buttonRemaining == 0 {
            comment = "已用完"
        } else if let lag = current.compactMap(\.commentLag).max() {
            if tone == .red && lag <= 0 { comment = nil }
            else if tone == .red || lag > 5 { comment = "超额 \(max(1, Int(lag.rounded())))%" }
            else if lag < -5 { comment = "余量 \(Int(-lag.rounded()))%" }
            else { comment = "进度正常" }
        } else {
            comment = current.isEmpty && !plan.isEmpty ? "已重置" : nil
        }
    }

    private struct Reading {
        let state: ReadState
        var title: String?
        var reason: String?
        var action: Action?
        var emptyLabel: String?

        func shortReason(for provider: ProviderRateLimit.Provider) -> String? {
            switch state {
            case .normal, .loading: emptyLabel
            case .needsLogin: provider == .zCode ? "需 Key" : "需登录"
            case .loginExpired: provider == .zCode ? "Key 无效" : "登录已失效"
            case .readFailed: "读取失败"
            case .paused: "已暂停读取"
            case .organizationPolicy: "组织策略"
            case .nonSubscriptionLogin: "未使用订阅登录"
            }
        }

        static func resolve(_ snapshot: ProviderRateLimit, refreshing: Bool, detected: Bool,
                            zCodeRegion: ZCodeQuotaRegion) -> Self {
            let failure = snapshot.liveFailure
            let reason = failure.map { QuotaStatusText.liveFailureText($0, provider: snapshot.provider) }
            if let failure, failure.isPause {
                return Self(state: failure.isNetworkPause ? .paused : .organizationPolicy, title: reason)
            }
            if snapshot.status != .ok && refreshing && snapshot.emptyReason != .limitReached {
                return Self(state: .loading, title: "正在读取…")
            }
            switch snapshot.status {
            case .ok: return Self(state: .normal)
            case .unauthorized:
                let title = QuotaStatusText.authorizationText(for: snapshot, zCodeRegion: zCodeRegion)
                return credentialOrReadFailure(snapshot, title: title, action: .retry)
            case .retryableError, .error:
                return Self(state: .readFailed, title: QuotaStatusText.readFailureTitle, reason: reason, action: .retry)
            case .disabled: return Self(state: .normal, title: "订阅配额未启用", emptyLabel: "未启用")
            case .noData:
                let text = QuotaStatusText.emptyStateText(for: snapshot, isDetected: detected)
                switch snapshot.emptyReason {
                case .nonessentialTrafficDisabled: return Self(state: .organizationPolicy, title: text)
                case .sessionWithoutPlanLimits: return Self(state: .nonSubscriptionLogin, title: text)
                case .noWindow: return Self(state: .normal, title: text, emptyLabel: "无窗口")
                case .notEntitled: return Self(state: .normal, title: text, emptyLabel: "未订阅")
                case .periodEnded: return Self(state: .normal, title: text, emptyLabel: "周期已结束")
                case .noLocalRecord: return Self(state: .normal, title: text, emptyLabel: "无本机记录")
                case .limitReached: return Self(state: .normal, title: "已用完")
                case nil:
                    if failure != nil {
                        return credentialOrReadFailure(snapshot, title: text)
                    }
                    let label = snapshot.fetchedAt == nil ? "尚未读取" : (detected ? "无数据" : "未检测到安装")
                    return Self(state: .normal, title: text, emptyLabel: label)
                }
            }
        }

        private static func credentialOrReadFailure(_ snapshot: ProviderRateLimit, title: String, action: Action? = nil) -> Self {
            let state: ReadState = switch snapshot.liveFailure {
            case .credentialsNotFound, .signInRequired: .needsLogin
            case .credentialsRejected where snapshot.provider == .antigravity: .needsLogin
            case .credentialsExpired, .credentialsRejected, .signInExpired: .loginExpired
            case nil: .loginExpired
            default: .readFailed
            }
            let opensSettings = snapshot.provider == .cursor && snapshot.liveFailure?.isCursorSignIn == true
            return Self(state: state, title: title, action: opensSettings ? .cursorSettings : action)
        }
    }
}

struct QuotaPanelMeter: Equatable {
    enum Prediction: Equatable {
        case untilReset
        case runsOutIn(TimeInterval)
    }

    let id: String
    let label: String
    let resetsAt: Date?
    let windowDuration: TimeInterval?
    let elapsed: TimeInterval?
    let timeUntilReset: TimeInterval?
    let breakdown: [RateLimitMeter.Part]
    fileprivate let primarySortDuration: TimeInterval?
    fileprivate let isExtra: Bool
    let remaining: Double?
    let usedPercent: Double?
    let expectedRemaining: Double?
    let prediction: Prediction?
    var message: String? { remaining == nil ? "已重置，等下次读取" : nil }
    let lag: Double?
    fileprivate var commentLag: Double? { tone == .red || prediction != nil ? lag : nil }
    let tone: QuotaPaceTone

    fileprivate static func rows(snapshot: ProviderRateLimit, modelMeters: [RateLimitMeter], now: Date) -> [Self] {
        var windows = snapshot.meters.filter { $0.id != "on-demand" }
        var extra = snapshot.meters.filter { $0.id == "on-demand" }
        if let spend = snapshot.extraUsage, spend.isEnabled, spend.limit > 0 {
            extra.append(.init(id: "extra", label: "额外", window: .init(utilization: spend.spend / spend.limit * 100)))
        }
        if let short = snapshot.fiveHour { windows.append(.init(id: "5h", label: "5h", window: short)) }
        if let weekly = snapshot.sevenDay { windows.append(.init(id: "7d", label: "7d", window: weekly)) }
        let generic = QuotaMeterLayout.canonicalMeters(windows, inferWindowDurations: false)
        let primaryLabels = ["5h", "7d"]
        let plan = generic.filter { primaryLabels.contains($0.label) } + generic.filter { !primaryLabels.contains($0.label) }
        // Generic periods precede feature meters. A feature can keep a leading
        // detail row, but only a recognized period gets a ring and an overview bar.
        let leading = plan.prefix(2).map {
            Self($0, primarySortDuration: QuotaMeterLayout.genericSortDuration(of: $0), now: now)
        }
        let other = plan.dropFirst(2)
        var ordered = modelMeters + other.filter { $0.label != "Month" }
        if let opus = snapshot.sevenDayOpus { ordered.append(.init(id: "opus", label: "Opus", window: opus)) }
        if let sonnet = snapshot.sevenDaySonnet { ordered.append(.init(id: "sonnet", label: "Sonnet", window: sonnet)) }
        ordered += other.filter { $0.label == "Month" }
        return leading + ordered.map { Self($0, now: now) } + extra.map { Self($0, isExtra: true, now: now) }
    }

    private init(_ meter: RateLimitMeter, primarySortDuration: TimeInterval? = nil, isExtra: Bool = false, now: Date) {
        id = meter.id
        label = isExtra ? "额外" : (meter.label == "Month" ? "mo" : meter.label)
        self.isExtra = isExtra
        self.primarySortDuration = primarySortDuration
        resetsAt = meter.window.resetsAt
        breakdown = meter.breakdown
        let window = meter.window
        let left = window.resetsAt?.timeIntervalSince(now)
        windowDuration = window.windowDuration.flatMap { $0 > 0 ? $0 : nil }
        timeUntilReset = left.flatMap { $0 > 0 ? $0 : nil }
        if let windowDuration, let timeUntilReset {
            elapsed = max(0, windowDuration - timeUntilReset)
        } else {
            elapsed = nil
        }
        if let left, left <= 0 {
            usedPercent = nil
            remaining = nil
            expectedRemaining = nil
            lag = nil
            prediction = nil
            tone = .neutral
            return
        }
        let used = min(100, max(0, window.utilization))
        usedPercent = used
        let remaining = 100 - used
        self.remaining = remaining
        guard !isExtra, let duration = windowDuration, let elapsed, let left else {
            expectedRemaining = nil
            lag = nil
            prediction = nil
            tone = !isExtra && remaining < 10 ? .red : .neutral
            return
        }
        expectedRemaining = min(100, left * 100 / duration)
        // Compare reported usage directly with elapsed percent. Subtracting decimal
        // remainders can turn an exact tie (e.g. 93.2% used) into a positive lag.
        let lag = used - elapsed * 100 / duration
        self.lag = lag
        if remaining == 0 {
            prediction = nil
            tone = .red
        } else if elapsed < duration * 0.15 {
            prediction = nil
            tone = remaining < 10 ? .red : .neutral
        } else {
            let eta = used > 0 ? remaining * elapsed / used : .infinity
            // At the current rate the quota runs out before reset exactly when usage is ahead of time.
            let runsOutBeforeReset = lag > 0
            prediction = runsOutBeforeReset ? .runsOutIn(eta) : .untilReset
            if left - eta >= 15 * 60 && (remaining < 10 || eta <= 3_600) { tone = .red }
            else if lag > 5 { tone = .amber }
            else { tone = .neutral }
        }
    }
}
