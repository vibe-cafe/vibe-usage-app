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

    let provider: ProviderRateLimit.Provider
    let planLabel: String?
    let resetCreditsCount: Int?
    let rows: [QuotaPanelMeter]
    let tightest: QuotaPanelMeter?
    let additionalAlert: QuotaPanelMeter?
    let outer: QuotaPanelMeter?
    let inner: QuotaPanelMeter?
    let tone: QuotaPaceTone
    let comment: String?
    private let reading: Reading
    let sourceNote: String?
    var buttonRemaining: Double? { reading == .exhausted ? 0 : tightest?.remaining }
    var showsSkeleton: Bool { reading == .loading }
    var detailTitle: String? {
        guard rows.isEmpty else { return nil }
        if case .failed = reading { return QuotaStatusText.readFailureTitle }
        return reading.message
    }
    var detailReason: String? {
        if case .failed(let reason) = reading { return reason }
        return nil
    }
    var showsWhiteDot: Bool {
        switch reading {
        case .paused, .login, .failed, .policy, .unreadable: true
        default: false
        }
    }
    var action: Action? {
        switch reading {
        case .login(_, let action): action
        case .failed: .retry
        default: nil
        }
    }
    var buttonStatus: String {
        if case .paused = reading { return "读取已暂停" }
        if let message = reading.message { return message }
        switch tone {
        case .red: return "快用完"
        case .amber: return "偏快"
        case .neutral: return tightest == nil ? (rows.first?.message ?? "暂无订阅配额数据") : "正常"
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
        reading = Reading(snapshot: snapshot, refreshing: refreshing, detected: detected, zCodeRegion: zCodeRegion)
        if snapshot.status == .ok && reading.displaysMeters {
            rows = QuotaPanelMeter.rows(snapshot: snapshot, modelMeters: modelMeters, now: now)
        } else {
            rows = []
        }
        sourceNote = rows.isEmpty ? nil : QuotaStatusText.sourceNote(for: snapshot)
        let plan = rows.filter { !$0.isExtra }
        let current = plan.filter { $0.remaining != nil }
        tightest = current.min { ($0.remaining ?? 100) < ($1.remaining ?? 100) }

        // Only primary windows draw rings. An expired primary must never paint its old reading.
        let rings = plan.prefix(2).filter { $0.remaining != nil }.sorted {
            ($0.sortDuration ?? 0) > ($1.sortDuration ?? 0)
        }
        outer = rings.first
        inner = rings.dropFirst().first
        let worst = current.max {
            ($0.tone.rawValue, $0.lag ?? -.infinity) < ($1.tone.rawValue, $1.lag ?? -.infinity)
        }
        tone = reading == .exhausted ? .red : worst?.tone ?? .neutral
        if let worst, worst.tone != .neutral, !rings.contains(worst) {
            additionalAlert = worst
        } else {
            additionalAlert = nil
        }
        if reading != .meters {
            comment = reading.comment
        } else if let lag = current.compactMap(\.commentLag).max() {
            if tone == .red && lag <= 0 { comment = nil }
            else if tone == .red || lag > 5 { comment = "超额 \(Int(lag.rounded()))%" }
            else if lag < -5 { comment = "余量 \(Int(-lag.rounded()))%" }
            else { comment = "进度正常" }
        } else {
            comment = current.isEmpty ? plan.first?.message : nil
        }
    }

    private enum Reading: Equatable {
        case meters, loading, exhausted
        case paused(String), policy(String), failed(String?), noPlan(String), empty(String), unreadable(String)
        case login(String, Action)

        var displaysMeters: Bool {
            switch self {
            case .paused, .meters: true
            default: false
            }
        }
        var message: String? {
            switch self {
            case .meters: nil
            case .loading: "正在读取…"
            case .exhausted: "已用完"
            case .failed(let reason): reason ?? QuotaStatusText.readFailureTitle
            case .login(let text, _), .paused(let text), .policy(let text),
                 .noPlan(let text), .empty(let text), .unreadable(let text): text
            }
        }
        var comment: String? {
            switch self {
            case .loading: nil
            case .paused: "已暂停读取"
            case .noPlan: "未使用订阅登录"
            default: message
            }
        }

        init(snapshot: ProviderRateLimit, refreshing: Bool, detected: Bool, zCodeRegion: ZCodeQuotaRegion) {
            if let failure = snapshot.liveFailure, failure.isPause,
               failure.isNetworkPause || snapshot.status != .ok {
                let reason = QuotaStatusText.liveFailureText(failure, provider: snapshot.provider)
                self = failure.isNetworkPause ? .paused(reason) : .policy(reason)
                return
            }
            if snapshot.emptyReason == .limitReached {
                self = .exhausted
                return
            }
            if snapshot.status != .ok && refreshing {
                self = .loading
                return
            }
            if snapshot.provider == .cursor, let failure = snapshot.liveFailure, failure.isCursorSignIn {
                self = .login(QuotaStatusText.liveFailureText(failure, provider: .cursor), .cursorSettings)
                return
            }
            switch snapshot.status {
            case .ok: self = .meters
            case .unauthorized: self = .login(QuotaStatusText.authorizationText(for: snapshot, zCodeRegion: zCodeRegion), .retry)
            case .retryableError, .error:
                self = .failed(snapshot.liveFailure.map { QuotaStatusText.liveFailureText($0, provider: snapshot.provider) })
            case .disabled: self = .empty("订阅配额未启用")
            case .noData:
                let text = QuotaStatusText.emptyStateText(for: snapshot, isDetected: detected)
                switch snapshot.emptyReason {
                case .nonessentialTrafficDisabled: self = .policy(text)
                case .sessionWithoutPlanLimits: self = .noPlan(text)
                case nil where snapshot.liveFailure != nil: self = .unreadable(text)
                default: self = .empty(text)
                }
            }
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
    fileprivate let sortDuration: TimeInterval?
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
        let other = plan.dropFirst(2)
        var ordered = Array(plan.prefix(2)) + modelMeters + other.filter { $0.label != "Month" }
        if let opus = snapshot.sevenDayOpus { ordered.append(.init(id: "opus", label: "Opus", window: opus)) }
        if let sonnet = snapshot.sevenDaySonnet { ordered.append(.init(id: "sonnet", label: "Sonnet", window: sonnet)) }
        ordered += other.filter { $0.label == "Month" }
        return ordered.map { Self($0, isExtra: false, now: now) } + extra.map { Self($0, isExtra: true, now: now) }
    }

    private init(_ meter: RateLimitMeter, isExtra: Bool, now: Date) {
        id = meter.id
        label = isExtra ? "额外" : (meter.label == "Month" ? "mo" : meter.label)
        self.isExtra = isExtra
        sortDuration = QuotaMeterLayout.sortDuration(of: meter)
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
            if runsOutBeforeReset && (remaining < 10 || eta <= 3_600) { tone = .red }
            else if lag > 5 { tone = .amber }
            else { tone = .neutral }
        }
    }
}
