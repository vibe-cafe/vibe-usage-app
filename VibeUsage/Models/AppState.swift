import Foundation
import SwiftUI

/// Sync status for menu bar icon display
enum SyncStatus: Equatable {
    case idle
    case syncing
    case success
    case error(String)
}

enum ChartMode: String, CaseIterable {
    case token = "Token"
    case cost = "\u{8D39}\u{7528}"
    case activeTime = "\u{6D3B}\u{8DC3}"
}

enum TimeRange: String, CaseIterable {
    /// Local midnight → now. Fixed start, only grows as the day progresses.
    /// Split out from `.oneDay` per vibe-cafe@f5f022b — the rolling-24h
    /// window confused users who read it as "today's spend" but watched the
    /// number shrink as the earliest hour rolled off. UI label: "今天".
    case today = "today"
    /// Rolling last 24 hours. UI label is "24H" (former "1D"); raw value
    /// stays "1D" for state stability across upgrades.
    case oneDay = "1D"
    case sevenDays = "7D"
    case thirtyDays = "30D"
    case ninetyDays = "90D"
    case custom = "custom"

    var fixedDayCount: Int {
        switch self {
        case .today, .oneDay: 1
        case .sevenDays: 7
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .custom: 7
        }
    }

    /// Inclusive lower bound on bucket / session timestamps when this range is
    /// active. nil means "show all fetched data" (which already matches the
    /// requested window for the day-granularity ranges). Currently only
    /// `.today` tightens the client-side window below what the API returned.
    var startCutoff: Date? {
        switch self {
        case .today: return Calendar.current.startOfDay(for: Date())
        default: return nil
        }
    }
}

/// Active filter selections
struct FilterState: Equatable {
    var sources: Set<String> = []
    var models: Set<String> = []
    var projects: Set<String> = []
    var hostnames: Set<String> = []

    var isEmpty: Bool {
        sources.isEmpty && models.isEmpty && projects.isEmpty && hostnames.isEmpty
    }

    mutating func clear() {
        sources.removeAll()
        models.removeAll()
        projects.removeAll()
        hostnames.removeAll()
    }
}

@Observable
@MainActor
final class AppState {
    // Resolve before initialize() writes menu-bar and quota preferences.
    let interfaceStyle: InterfaceStylePreference

    /// Navigation of the new panel (概览 or one subscription, hero, expanded).
    let modernPanel = ModernPanelState()

    /// The panel's 「登录并链接数据」 sign-in, shared by the classic and the new
    /// panel so it survives closing the panel and switching the style.
    @ObservationIgnored private(set) lazy var deviceLink: DeviceLinkFlow = makeDeviceLink()
    /// What every device sign-in of this app reaches (a seam for tests).
    @ObservationIgnored let deviceLinkService: DeviceLinkService

    // MARK: - Sync State
    var syncStatus: SyncStatus = .idle
    var lastSyncTime: Date?
    var lastSyncMessage: String?
    private var lastFetchTime: Date?
    /// The last sync that succeeded, kept in the app's preferences so the new
    /// panel's footer can still say 「N 分钟前同步」 after a restart. The
    /// classic footer keeps reading the in-memory `lastSyncTime`.
    private(set) var lastSuccessfulSyncAt: Date?
    static let lastSuccessfulSyncKey = "lastSuccessfulSyncAt"

    /// Runs one CLI sync. A seam for tests, which must never start the CLI.
    @ObservationIgnored var runSync: @MainActor () async -> (
        result: Result<String, SyncEngine.SyncError>, outcome: SyncEngine.Outcome?
    ) = { await SyncEngine.shared.runSync() }
    /// Builds the quota coordinator. A seam for tests, which inject fake readers.
    @ObservationIgnored var makeRateLimitCoordinator: @MainActor (AppState) -> RateLimitCoordinator = {
        RateLimitCoordinator(appState: $0)
    }
    /// Writes the shared config when linking. A seam for tests, which must
    /// never write `~/.vibe-usage`.
    @ObservationIgnored var saveConfig: @MainActor (VibeUsageConfig) -> Void = { ConfigManager.save($0) }

    // MARK: - Dashboard Data
    var buckets: [UsageBucket] = []
    private(set) var activity: ActivityReport?
    private var activityTask: Task<Void, Never>?
    private var modernActivityTask: Task<Void, Never>?
    private var activityRange: UsageQueryRange?
    private var lastActivityFilterItems: [URLQueryItem]?
    var isLoadingActivity: Bool {
        if interfaceStyle.current == .modern && activity != nil { return false }
        return activityTask != nil || modernActivityTask != nil || (activityRange != nil && lastActivityFilterItems == nil)
    }
    private struct ActivityQuery: Hashable {
        let range: UsageQueryRange
        let items: [URLQueryItem]
    }
    private let usageCache = RangeReadCache<UsageQueryRange, UsageResponse>()
    private let activityCache = RangeReadCache<ActivityQuery, ActivityReport>()
    @ObservationIgnored var usageNow: () -> Date = Date.init
    private var cacheDay: Date?
    private var lastPrefetchOpen: Date?
    var hasAnyData: Bool = false
    var isLoadingData: Bool = false
    var hasLoadedUsageData: Bool = false
    private var usageFetchGeneration: UInt = 0
    private var loadedUsageRange: UsageQueryRange?
    /// Changes whenever the account or server changes (link, relink, reset):
    /// figures a view kept from before belong to someone else.
    private(set) var usageAccount: UInt = 0
    /// Counts the usage reads that ended, success or failure (the newest one
    /// only). A view keyed on it sees every end, even when the loading flag
    /// went on and off between two of its updates.
    private(set) var usageReadsFinished: UInt = 0
    /// The range the newest usage read asked for (nil after an account change).
    private var attemptedUsageRange: UsageQueryRange?

    /// The selected period has not been asked for yet: it just changed and
    /// its read follows in a task, or the day rolled over. Cards treat this
    /// like a running read, so a period change fades the previous figures
    /// instead of flashing 「—」 before the read starts.
    var isUsageReadPending: Bool {
        isConfigured && attemptedUsageRange != currentQueryRange
    }

    var isInitialDataLoad: Bool {
        isLoadingData && !hasLoadedUsageData && buckets.isEmpty
    }

    var isRefreshingData: Bool {
        isLoadingData && hasLoadedUsageData
    }

    // MARK: - Dashboard Controls
    var timeRange: TimeRange = .oneDay
    var customRangeFrom: Date = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    var customRangeTo: Date = Calendar.current.startOfDay(for: Date())
    var chartMode: ChartMode = .token
    var filters: FilterState = .init() {
        didSet { reloadActivityIfFiltersChanged() }
    }

    /// Compare the actual server parameters, including those of a pending read.
    private var activityFiltersChanged: Bool {
        activityRange != nil && activityFilters.activityQueryItems != lastActivityFilterItems
    }

    /// Hide the previous selection immediately when the read is scheduled in a task.
    private func discardActivityIfFiltersChanged() {
        guard activityFiltersChanged else { return }
        activityTask?.cancel()
        activityTask = nil
        modernActivityTask = nil
        lastActivityFilterItems = nil
        activity = nil
    }

    private func reloadActivityIfFiltersChanged() {
        guard let range = activityRange, activityFiltersChanged else { return }
        reloadConfig()
        guard let key = config?.apiKey else { return }
        if activityRange == nil {
            // Disk configuration switched accounts; refresh both halves of the dashboard.
            Task { await fetchUsageData() }
        } else if interfaceStyle.current == .modern {
            expireHourlyResults()
            _ = readModernActivity(currentQueryRange, key: key, reuseFor: 60, display: true)
        } else {
            startActivityFetch(range: range, key: key)
        }
    }

    /// Display names and family rows the server sent with the current usage.
    /// `nil` until the first successful fetch, or when an older server answers —
    /// every lookup below then falls back to the raw id, which is the same
    /// "cannot resolve" behaviour the app has always had.
    private(set) var usageNames: UsageNames?

    /// Product name for an upload source, or the source id as reported.
    func toolName(_ source: String) -> String {
        usageNames?.sources[source] ?? source
    }

    /// Official model name, or the raw id as reported. This is the single place
    /// the app turns a reported model id into something a human reads; the
    /// rules behind it live in the server, not here.
    func modelName(_ model: String) -> String {
        usageNames?.models[model] ?? model
    }

    /// Family rows to group the model filter by, in the server's order.
    var modelFamilies: [UsageFamily] { usageNames?.families ?? [] }

    /// The family a reported model id belongs to, or nil when the server could
    /// not place it (it then shows under 其他).
    func familyKey(forModel model: String) -> String? {
        usageNames?.modelFamilies[model]
    }

    /// Display name → family key, resolved through the raw ids behind each name.
    ///
    /// `modelFamilies` is keyed by raw id because that is what a tool reports,
    /// while the filter lists one option per display name (one name merges
    /// several ids). Single pass over the buckets rather than a scan per name.
    var familyKeyByDisplayName: [String: String] {
        var map: [String: String] = [:]
        for bucket in buckets where map[modelName(bucket.model)] == nil {
            if let key = usageNames?.modelFamilies[bucket.model] {
                map[modelName(bucket.model)] = key
            }
        }
        return map
    }

    /// The model filter's options, grouped by the family the server placed each
    /// display name in.
    ///
    /// Built entirely from the server's `families` / `modelFamilies`, in the
    /// server's order, so the app carries no family table of its own — the
    /// macOS and Windows apps used to keep two hand-synced copies of one.
    var modelFilterGroups: [ModelFilterGroup] {
        let familyByDisplayName = familyKeyByDisplayName
        var members: [String: [String]] = [:]
        var unplaced: [String] = []
        for name in Set(buckets.map { modelName($0.model) }).sorted() {
            if let key = familyByDisplayName[name] {
                members[key, default: []].append(name)
            } else {
                unplaced.append(name)
            }
        }
        var groups = modelFamilies.compactMap { family -> ModelFilterGroup? in
            guard let names = members[family.key], !names.isEmpty else { return nil }
            return ModelFilterGroup(key: family.key, label: family.label, models: names)
        }
        if !unplaced.isEmpty {
            groups.append(ModelFilterGroup(key: "other", label: "其他", models: unplaced))
        }
        return groups
    }

    /// The one filter predicate. Every view that narrows its data by the filter
    /// bar asks here, so a change to how a dimension matches — models now match
    /// on the *display name*, because one name merges several reported ids —
    /// cannot be applied in one view and forgotten in the next three.
    func matchesFilters(_ bucket: UsageBucket) -> Bool {
        if !filters.sources.isEmpty && !filters.sources.contains(bucket.source) { return false }
        if !filters.models.isEmpty && !filters.models.contains(modelName(bucket.model)) { return false }
        if !filters.projects.isEmpty && !filters.projects.contains(bucket.project) { return false }
        if !filters.hostnames.isEmpty && !filters.hostnames.contains(bucket.hostname) { return false }
        return true
    }

    var currentQueryRange: UsageQueryRange {
        queryRange(at: usageNow())
    }

    private func queryRange(for period: TimeRange? = nil, at now: Date) -> UsageQueryRange {
        switch period ?? timeRange {
        case .today:
            return .from(Calendar.current.startOfDay(for: now))
        case .oneDay:
            return .days(1)
        case .sevenDays:
            return .days(7)
        case .thirtyDays:
            return .days(30)
        case .ninetyDays:
            return .days(90)
        case .custom:
            let bounds = normalizedCustomRange
            return .custom(from: bounds.from, to: bounds.to)
        }
    }

    /// Apply at launch before the first fetch, and whenever the interface style changes.
    func applyDefaultTimeRange(forModernInterface modern: Bool) {
        timeRange = modern ? .today : .oneDay
    }

    /// The current style's default period (new panel 今天, classic 24H);
    /// `initialize()` calls it before the launch fetch.
    func applyDefaultTimeRangeForInterfaceStyle() {
        applyDefaultTimeRange(forModernInterface: interfaceStyle.current == .modern)
    }

    /// 「界面样式」: switch the style, then put the period on its default.
    /// A changed period is read again, the same read a period change makes.
    /// If just the effective tool or project changes, only active time is read again.
    /// A real switch here ends both style reminders (`InterfaceStylePreference.select`).
    func selectInterfaceStyle(_ style: InterfaceStyle) {
        switchInterfaceStyle { interfaceStyle.select(style) }
    }

    /// The classic panel's banner, 「切换新版」: the same switch, after which
    /// the new panel says once where to switch back.
    func acceptClassicStyleReminder() {
        switchInterfaceStyle { interfaceStyle.acceptClassicReminder() }
    }

    private func switchInterfaceStyle(_ change: () -> Void) {
        let previous = interfaceStyle.current
        change()
        guard interfaceStyle.current != previous else { return }
        let range = timeRange
        applyDefaultTimeRangeForInterfaceStyle()
        if previous == .modern {
            // Classic may inherit a foreground read with identical parameters.
            // Stop the speculative requests and let its usual refresh take over.
            let current = currentQueryRange
            usageCache.remove { $0 != current || attemptedUsageRange != current }
            activityCache.remove { $0.range != current || $0.items != activityFilters.activityQueryItems }
            lastPrefetchOpen = nil
        }
        if timeRange != range {
            discardActivityIfFiltersChanged()
            Task { await fetchUsageData() }
        } else {
            reloadActivityIfFiltersChanged()
        }
    }

    /// The slots of the new panel's activity curve. Active time is filtered
    /// by period, terminal and tool, never by model, so a model filter does
    /// not cut its start: the slots of the usage without the model filter,
    /// or the period's whole grid when there is none. Nil like the snapshot.
    func activityPlotGrid(filters: UsagePanelFilters, now: Date) -> UsagePlotGrid? {
        guard let loadedUsageRange = loadedRange(at: now) else { return nil }
        var activityFilters = filters
        activityFilters.models = []
        let usage = UsageDisplaySnapshot(buckets: buckets, dataRange: loadedUsageRange, filters: activityFilters,
                                         modelName: modelName, toolName: toolName, now: now)
        return usage.series.isEmpty ? UsagePlotGrid(dataRange: loadedUsageRange, now: now, calendar: .current) : usage.grid
    }

    func usageDisplaySnapshot(filters: UsagePanelFilters, now: Date) -> UsageDisplaySnapshot? {
        guard let loadedUsageRange = loadedRange(at: now) else { return nil }
        return UsageDisplaySnapshot(buckets: buckets, dataRange: loadedUsageRange, filters: filters,
                                    modelName: modelName, toolName: toolName, now: now)
    }

    private func loadedRange(at now: Date) -> UsageQueryRange? {
        guard let loadedUsageRange, loadedUsageRange == queryRange(at: now) else { return nil }
        // Unlike Today, the rolling day's query is identical across midnight.
        if interfaceStyle.current == .modern, loadedUsageRange == .days(1), let cacheDay,
           !Calendar.current.isDate(cacheDay, inSameDayAs: now) { return nil }
        return loadedUsageRange
    }

    var visibleDayCount: Int {
        if timeRange != .custom { return timeRange.fixedDayCount }
        let bounds = normalizedCustomRange
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: bounds.from)
        let to = calendar.startOfDay(for: bounds.to)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        return max(days + 1, 1)
    }

    var normalizedCustomRange: (from: Date, to: Date) {
        if customRangeFrom <= customRangeTo {
            return (customRangeFrom, customRangeTo)
        }
        return (customRangeTo, customRangeFrom)
    }

    // MARK: - Config
    var isConfigured: Bool = false
    /// False only after a sync found no usable runtime (bundled Node failed its
    /// probe and no system Node.js or Bun exists). Learned from the sync, not
    /// at launch, so the bundled Node's probe never runs on the main thread.
    var runtimeAvailable: Bool = true

    // MARK: - Subscription Quotas
    private(set) var quotaProducts: [QuotaProduct] = QuotaProductRegistry.catalog.map {
        QuotaProduct(provider: $0.0, availability: $0.1, isDetected: false)
    }
    private(set) var selectedQuotaProviders: [ProviderRateLimit.Provider] = [.codex, .claudeCode] {
        didSet {
            if interfaceStyle.current == .modern { reloadActivityIfFiltersChanged() }
        }
    }
    /// Persisted display order of every catalog product, enabled or not. The
    /// strip renders enabled products first, so this order decides the sequence
    /// *within* each of those two groups.
    private(set) var quotaProductOrder: [ProviderRateLimit.Provider] = []
    /// The tab whose card is on screen. Falls back to the first tab when the
    /// stored product is gone.
    private(set) var selectedQuotaTab: ProviderRateLimit.Provider = .codex
    var rateLimits: [ProviderRateLimit] = []

    /// True while the corresponding provider's refresh is in flight — the card
    /// header shows a mini spinner. Codex refreshes now include a network
    /// round-trip (~1s), so unlike the old file-only reads the latency is
    /// user-perceivable and needs an indicator.
    var isCodexRateLimitRefreshing: Bool = false
    var isClaudeRateLimitRefreshing: Bool = false
    /// OpenCode Go fetches over the network like Codex, so it needs the same
    /// in-flight indicator.
    var isOpenCodeGoRateLimitRefreshing: Bool = false
    var cliQuotaRefreshingProviders: Set<ProviderRateLimit.Provider> = []
    private(set) var zCodeAPIKeyConfigured = false
    private(set) var zCodeQuotaRegion: ZCodeQuotaRegion = .bigModel

    /// Compatibility projections for the native provider adapters. The source
    /// of truth is the ordered selector above; these keep the existing readers
    /// focused while the other products move onto the shared CLI contract.
    var codexRateLimitEnabled: Bool {
        get { selectedQuotaProviders.contains(.codex) }
        set { updateQuotaSelection(provider: .codex, selected: newValue) }
    }
    var claudeRateLimitEnabled: Bool {
        get { selectedQuotaProviders.contains(.claudeCode) }
        set { updateQuotaSelection(provider: .claudeCode, selected: newValue) }
    }

    // MARK: - Menu Bar Display Prefs
    var showCostInMenuBar: Bool = true {
        didSet { UserDefaults.standard.set(showCostInMenuBar, forKey: "showCostInMenuBar") }
    }
    var showTokensInMenuBar: Bool = false {
        didSet { UserDefaults.standard.set(showTokensInMenuBar, forKey: "showTokensInMenuBar") }
    }
    var showInDock: Bool = true {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            ActivationCoordinator.shared.applyDockPreference()
        }
    }
    /// 「没检测到代理时」 (`EgressCheck.Mode`), default 「自动判断」; read again
    /// at every check and passed to the CLI, so a change applies to the next read.
    var egressMode: EgressCheck.Mode = .auto {
        didSet { EgressCheck.setMode(egressMode) }
    }

    // MARK: - Menu Bar Stats (matches current time range, no filters)

    /// Buckets within the active range's window. `.today` and `.oneDay` both
    /// fetch `days=1`, so `buckets` is identical for both — the only thing that
    /// distinguishes them is the client-side `startCutoff`. The popover views
    /// apply that cutoff; the menu bar must too, or toggling 今天 ↔ 24H leaves
    /// the menu bar stuck on the full-24h total (see vibe-cafe@f5f022b).
    private var menuBarBuckets: [UsageBucket] {
        guard let cutoff = timeRange.startCutoff else { return buckets }
        return buckets.filter { bucket in
            guard let date = bucket.date else { return true }
            return date >= cutoff
        }
    }

    var menuBarCost: Double {
        menuBarBuckets.reduce(0) { $0 + ($1.estimatedCost ?? 0) }
    }

    var menuBarTokens: Int {
        menuBarBuckets.reduce(0) { $0 + $1.computedTotal }
    }
    // MARK: - Services (initialized after launch)
    private var syncScheduler: SyncScheduler?
    private var rateLimitCoordinator: RateLimitCoordinator?
    private var isPanelVisible = false
    private var config: VibeUsageConfig?
    private let loadConfig: () -> VibeUsageConfig?
    var usageServer: UsageServer { UsageServer(config?.apiUrl) }
    private let usageFetcher: (UsageServer, String, UsageQueryRange) async throws -> UsageResponse
    /// Server, key, range, filters, and whether to ask for hour periods.
    private let activityFetcher: (UsageServer, String, UsageQueryRange, FilterState, Bool) async throws -> UsageActivity
    private let quotaDefaults: UserDefaults
    private let zCodeAPIKeyStore: any ZCodeAPIKeyStoring
    private let quotaProductDiscoverer: () -> [QuotaProduct]
    /// The Cursor sign-in Vibe Usage keeps (Settings → 订阅配额 → Cursor).
    let cursorLogin: CursorLogin

    init(
        initialConfig: VibeUsageConfig? = nil,
        loadConfig: @escaping () -> VibeUsageConfig? = ConfigManager.load,
        usageFetcher: @escaping (UsageServer, String, UsageQueryRange) async throws -> UsageResponse = { server, apiKey, range in
            try await APIClient(server: server, apiKey: apiKey).fetchUsage(range: range)
        },
        activityFetcher: @escaping (UsageServer, String, UsageQueryRange, FilterState, Bool) async throws -> UsageActivity = { server, key, range, filters, hourly in
            try await APIClient(server: server, apiKey: key).fetchActivity(range: range, filters: filters, hourly: hourly)
        },
        quotaDefaults: UserDefaults = .standard,
        zCodeAPIKeyStore: any ZCodeAPIKeyStoring = KeychainZCodeAPIKeyStore(),
        quotaProductDiscoverer: @escaping () -> [QuotaProduct] = {
            QuotaProductRegistry.discover()
        },
        cursorLogin: CursorLogin? = nil,
        interfaceStyle: InterfaceStylePreference = .shared,
        deviceLinkService: DeviceLinkService = .live
    ) {
        self.interfaceStyle = interfaceStyle
        self.deviceLinkService = deviceLinkService
        self.config = initialConfig
        self.loadConfig = loadConfig
        self.isConfigured = initialConfig?.apiKey != nil
        self.usageFetcher = usageFetcher
        self.activityFetcher = activityFetcher
        self.quotaDefaults = quotaDefaults
        self.zCodeAPIKeyStore = zCodeAPIKeyStore
        self.quotaProductDiscoverer = quotaProductDiscoverer
        self.cursorLogin = cursorLogin ?? .shared
        modernPanel.onSubscriptionSelection = { [weak self] in
            guard let self, self.interfaceStyle.current == .modern else { return }
            self.reloadActivityIfFiltersChanged()
        }
        if let saved = quotaDefaults.object(forKey: Self.lastSuccessfulSyncKey) as? Date {
            self.lastSuccessfulSyncAt = saved
        } else if let migrated = SyncHistoryStore(defaults: quotaDefaults).records()
            .first(where: { $0.result == .success })
            .map({ $0.startedAt.addingTimeInterval($0.duration) }) {
            // Releases before the key existed still kept their recent syncs.
            // Saved at once, before later failures push that record out.
            self.lastSuccessfulSyncAt = migrated
            quotaDefaults.set(migrated, forKey: Self.lastSuccessfulSyncKey)
        }
    }

    // MARK: - Lifecycle

    func initialize() {
        // The new panel opens on 今天, the classic one on 24H, from the first fetch on.
        applyDefaultTimeRangeForInterfaceStyle()
        // Load menu bar prefs
        self.showCostInMenuBar = UserDefaults.standard.object(forKey: "showCostInMenuBar") as? Bool ?? true
        self.showTokensInMenuBar = UserDefaults.standard.object(forKey: "showTokensInMenuBar") as? Bool ?? false
        self.showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        self.egressMode = EgressCheck.mode()
        initializeQuotaProducts()
        cursorLogin.load()
        cursorLogin.onAccountChange = { [weak self] signedIn in
            await self?.cursorSignInDidChange(signedIn: signedIn)
        }

        #if DEBUG
        // UI acceptance builds can exercise subscription cards without
        // reading a production Vibe account config or starting its sync/upload
        // scheduler. The environment hook is compiled out of Release.
        if ProcessInfo.processInfo.environment["VIBE_USAGE_QUOTA_UI_TEST"] == "1" {
            self.isConfigured = true
            self.hasLoadedUsageData = true
            // Preview builds can show fixed sample usage so the menu bar and
            // the Settings preview have figures to display.
            if ProcessInfo.processInfo.environment["VIBE_USAGE_SAMPLE_USAGE"] == "1" {
                self.buckets = Self.sampleUsageBuckets()
                self.loadedUsageRange = currentQueryRange
            }
            if !selectedQuotaProviders.isEmpty {
                startRateLimitCoordinator()
            }
            return
        }
        #endif

        // Hand back the `statusLine.command` edit the pre-probe releases made.
        LegacyStatuslineRetirement.run()

        reloadConfig()

        // Nothing to send (not linked, no quota product selected): no reason
        // to look at the proxy at all.
        if launchWaitsForProxy, launchProxyWait == nil, isConfigured || !selectedQuotaProviders.isEmpty {
            let urls = LoginLaunch.proxyProbeURLs(server: Self.launchProbeURL())
            launchProxyWait = Task.detached(priority: .utility) {
                let up = await LoginLaunch.waitForProxy(urls: urls)
                debugLog("[launch] \(up ? "proxy is up or none configured" : "proxy wait ran out") — network reads go ahead")
            }
        }
        if isConfigured {
            // Only a login launch waits, for the proxy (`LoginLaunch`); a
            // link made while that wait runs waits too.
            startScheduler()
        }

        // Subscription quotas are independent of Vibe Usage account linking.
        // Start only when a product is selected; discovery itself is local and
        // never starts a network request.
        if !selectedQuotaProviders.isEmpty {
            startRateLimitCoordinator()
        }
    }

    /// Initializes only local quota discovery, app-owned key state, and the
    /// persisted product selection. Kept separate from account/sync startup
    /// so this policy can be tested without touching real user configuration.
    func initializeQuotaProducts() {
        self.quotaProducts = quotaProductDiscoverer()
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        TestDiagnosticLog.recordQuotaProductsDiscovered(
            quotaProducts.filter(\.isDetected).map(\.provider)
        )
        #endif
        let persistedRegion = quotaDefaults.string(forKey: ZCodeQuotaRegion.defaultsKey)
            .flatMap(ZCodeQuotaRegion.init(rawValue:))
        // Existing releases stored only a Z.ai key. Preserve that region on
        // upgrade; a fresh setup starts on BigModel but performs no request
        // until the user explicitly saves a key and selects ZCode.
        let legacyZAIKeyExists = (try? zCodeAPIKeyStore.load(for: .zAI)) != nil
        self.zCodeQuotaRegion = persistedRegion ?? (legacyZAIKeyExists ? .zAI : .bigModel)
        self.zCodeAPIKeyConfigured = (
            try? zCodeAPIKeyStore.load(for: zCodeQuotaRegion)
        ) != nil
        // On a fresh install, a detected ZCode client without an explicitly
        // configured API key is not one of the auto-selected defaults — it
        // would only ever show a "configure me" card. Stored/migrated
        // selections still round-trip exactly.
        let initiallySelectableProducts = quotaProducts.map { product in
            guard product.provider == .zCode, !zCodeAPIKeyConfigured else { return product }
            var unavailable = product
            unavailable.availability = .pendingProtocol
            return unavailable
        }
        self.selectedQuotaProviders = QuotaSelectionPreferences.resolve(
            defaults: quotaDefaults,
            products: initiallySelectableProducts
        )
        // The tab strip remembers both the display order of every product and
        // which tab the user last looked at. Order is stored for the whole
        // catalog (enabled or not), because disabled tabs stay visible — they
        // are simply rendered after the enabled ones and greyed out.
        self.quotaProductOrder = QuotaSelectionPreferences.resolveOrder(
            defaults: quotaDefaults,
            products: quotaProducts
        )
        self.selectedQuotaTab = QuotaSelectionPreferences.resolveSelectedTab(
            defaults: quotaDefaults,
            order: quotaTabOrder
        )
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        TestDiagnosticLog.recordQuotaSelectionInitialized(selectedQuotaProviders)
        #endif
    }

    /// Pick up CLI edits as one snapshot, so the key always belongs to the same server.
    func reloadConfig() {
        if let latest = loadConfig() {
            applyConfig(latest)
        }
    }

    func applyConfig(_ latest: VibeUsageConfig?) {
        if latest == nil || config?.apiKey != latest?.apiKey || usageServer != UsageServer(latest?.apiUrl) {
            // A pending response or cached dashboard belongs to the previous account/server.
            usageFetchGeneration &+= 1
            usageAccount &+= 1
            clearRangeCaches()
            activityTask?.cancel()
            activityTask = nil
            activityRange = nil
            lastActivityFilterItems = nil
            activity = nil
            lastFetchTime = nil
            hasLoadedUsageData = false
            isLoadingData = false
            hasAnyData = false
            loadedUsageRange = nil
            attemptedUsageRange = nil
            buckets = []
            usageNames = nil
        }
        config = latest
        isConfigured = latest?.apiKey != nil
        // A reset drops the launch sync that has not started yet, and the
        // last sync time goes with the account.
        if latest == nil {
            launchSyncTask?.cancel()
            lastSuccessfulSyncAt = nil
            quotaDefaults.removeObject(forKey: Self.lastSuccessfulSyncKey)
        }
    }

    /// Save the server selected by device authorization and start the scheduler.
    func configure(apiKey: String, server: UsageServer) {
        var cfg = loadConfig() ?? VibeUsageConfig()
        cfg.apiKey = apiKey
        cfg.apiUrl = server.baseURL
        saveConfig(cfg)

        applyConfig(loadConfig())
        if isConfigured {
            startScheduler()
        }
    }

    // MARK: - Sync

    func triggerSync(_ trigger: SyncRecord.Trigger = .manual) async {
        guard syncStatus != .syncing else { return }
        syncStatus = .syncing
        // Any sync, manual ones too, waits for a login launch's proxy. A reset
        // or relink in the meantime drops this one.
        let account = config?.apiKey
        await waitForLaunchNetwork()
        guard config?.apiKey == account else {
            await dropStaleSync(trigger)
            return
        }

        let startedAt = Date()
        let (result, outcome) = await runSync()
        // Reset or relinked while the CLI ran: the result belongs to the
        // previous account, so it is neither recorded nor shown.
        guard config?.apiKey == account else {
            await dropStaleSync(trigger)
            return
        }
        if let outcome {
            syncHistory.append(SyncRecord(
                startedAt: startedAt,
                duration: Date().timeIntervalSince(startedAt),
                trigger: trigger,
                result: outcome.result,
                reason: outcome.reason,
                httpStatus: outcome.httpStatus,
                exitCode: outcome.exitCode,
                launcherStage: outcome.launcherStage,
                cliFallback: outcome.cliFallback
            ))
            runtimeAvailable = outcome.reason != .runtimeMissing
        }

        switch result {
        case .success(let message):
            syncStatus = .success
            let finishedAt = Date()
            lastSyncTime = finishedAt
            lastSuccessfulSyncAt = finishedAt
            quotaDefaults.set(finishedAt, forKey: Self.lastSuccessfulSyncKey)
            lastSyncMessage = message
            if interfaceStyle.current == .modern {
                let current = currentQueryRange
                let cutoff = usageNow().addingTimeInterval(-60)
                usageCache.markStale(asOf: cutoff) { $0 != current }
                activityCache.markStale(asOf: cutoff) { $0.range != current }
            }
            await fetchUsageData()
            // Reset to idle after a delay
            try? await Task.sleep(for: .seconds(3))
            if syncStatus == .success {
                syncStatus = .idle
            }
        case .failure(let error):
            syncStatus = .error(error.localizedDescription)
            lastSyncMessage = error.localizedDescription
        }
    }

    /// The account changed under a sync (reset, relink). After a relink the
    /// new account is synced instead: its own launch sync returned at once
    /// while this one held the status. That run gets a task of its own — the
    /// stale run may be the launch task the relink cancelled, and a cancelled
    /// task would stop the new account's CLI too.
    private func dropStaleSync(_ trigger: SyncRecord.Trigger) async {
        syncStatus = .idle
        guard config?.apiKey != nil else { return }
        await Task { await self.triggerSync(trigger) }.value
    }

    // MARK: - Data Fetching

    private var usesFixtureDashboard: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["VIBE_USAGE_QUOTA_UI_TEST"] == "1"
        #else
        false
        #endif
    }

    private func clearRangeCaches() {
        usageCache.remove()
        activityCache.remove()
        modernActivityTask = nil
        cacheDay = nil
        lastPrefetchOpen = nil
    }

    func calendarDayDidChange() {
        if isPanelVisible {
            selectUsagePeriod(timeRange)
        } else {
            expireHourlyResults()
        }
    }

    private func expireHourlyResults() {
        guard interfaceStyle.current == .modern else { return }
        let today = Calendar.current.startOfDay(for: usageNow())
        defer { cacheDay = today }
        guard let cacheDay, cacheDay != today else { return }
        usageCache.remove { $0.isHourly }
        activityCache.remove { $0.range.isHourly }
        lastPrefetchOpen = nil
        if loadedUsageRange?.isHourly == true {
            loadedUsageRange = nil
            buckets = []
            hasAnyData = false
            usageNames = nil
            usageReadsFinished &+= 1
        }
        if attemptedUsageRange?.isHourly == true {
            attemptedUsageRange = nil
            lastFetchTime = nil
            isLoadingData = false
        }
        if activityRange?.isHourly == true {
            activityRange = nil
            modernActivityTask = nil
            lastActivityFilterItems = nil
            activity = nil
        }
    }

    /// Called by both modern period pickers. Paint a cached answer in the
    /// same update as the selection, even if its refresh will take a while.
    func selectUsagePeriod(_ period: TimeRange) {
        guard interfaceStyle.current == .modern else { return }
        timeRange = period
        guard !usesFixtureDashboard else { return }
        reloadConfig()
        guard let key = config?.apiKey else { return }
        expireHourlyResults()
        _ = readModernRange(currentQueryRange, key: key, reuseFor: 60, display: true)
    }

    private typealias DashboardReads = (usage: Task<Void, Never>?, activity: Task<Void, Never>?)

    private func readModernRange(_ range: UsageQueryRange, key: String, reuseFor interval: TimeInterval,
                                 display: Bool, onOpen: Bool = false) -> DashboardReads {
        let activity = readModernActivity(range, key: key, reuseFor: interval, display: display, onOpen: onOpen)
        let cached = usageCache[range]
        if display {
            usageFetchGeneration &+= 1
            attemptedUsageRange = range
            if let cached { showUsage(cached, for: range) }
        }
        let task = usageCache.read(range, reuseFor: interval, debounceFailure: onOpen, now: usageNow) {
            [server = usageServer] in
            await self.waitForLaunchNetwork()
            try Task.checkCancellation()
            return try await self.usageFetcher(server, key, range)
        } finished: { [weak self] response in
            guard let self else { return }
            self.expireHourlyResults()
            guard self.currentQueryRange == range, self.attemptedUsageRange == range else { return }
            if let response { self.showUsage(response, for: range) }
            self.lastFetchTime = self.usageNow()
            self.isLoadingData = false
            self.hasLoadedUsageData = true
            self.usageReadsFinished &+= 1
        }
        if display { isLoadingData = task != nil && loadedUsageRange != range }
        return (task, activity)
    }

    private func showUsage(_ response: UsageResponse, for range: UsageQueryRange) {
        buckets = response.buckets
        hasAnyData = response.hasAnyData
        loadedUsageRange = range
        hasLoadedUsageData = true
        usageNames = response.names
    }

    private func readModernActivity(_ range: UsageQueryRange, key: String, reuseFor interval: TimeInterval,
                                    display: Bool, onOpen: Bool = false) -> Task<Void, Never>? {
        let filters = activityFilters
        let query = ActivityQuery(range: range, items: filters.activityQueryItems)
        if display {
            activityTask?.cancel()
            activityTask = nil
            activity = activityCache[query]
            activityRange = range
            lastActivityFilterItems = query.items
        }
        let start = range.start(at: usageNow())
        let hourly = activityIsHourly(range)
        let task = activityCache.read(query, reuseFor: interval, debounceFailure: onOpen, now: usageNow) {
            [server = usageServer] in
            await self.waitForLaunchNetwork()
            try Task.checkCancellation()
            let result = try await self.activityFetcher(server, key, range, filters, hourly)
            return ActivityReport(result, rangeStart: start, hourly: hourly)
        } finished: { [weak self] report in
            guard let self else { return }
            self.expireHourlyResults()
            guard self.activityRange == range,
                  self.lastActivityFilterItems == query.items else { return }
            self.activity = report
            self.modernActivityTask = nil
        }
        if display { modernActivityTask = task }
        return task
    }

    private func openModernUsage() -> Task<Void, Never>? {
        guard !usesFixtureDashboard else { return nil }
        reloadConfig()
        guard let key = config?.apiKey else { return nil }
        expireHourlyResults()
        let now = usageNow()
        let account = usageAccount
        let shouldPrefetch = lastPrefetchOpen.map { now.timeIntervalSince($0) >= 60 } ?? true
        if shouldPrefetch { lastPrefetchOpen = now }
        let openedRange = currentQueryRange
        let reads = readModernRange(openedRange, key: key, reuseFor: 60, display: true, onOpen: true)
        return Task {
            await reads.usage?.value
            await reads.activity?.value
            if shouldPrefetch, usageCache.lastReadSucceeded(for: openedRange) {
                await prefetchQuickPeriods(openedAt: now, account: account)
            }
        }
    }

    private func prefetchQuickPeriods(openedAt: Date, account: UInt) async {
        // A click or filter change during the open may have selected a slower
        // request. Give that selection the same priority as the opening one.
        while lastPrefetchOpen == openedAt {
            let usage = usageCache.inFlight(for: currentQueryRange)
            let activity = modernActivityTask
            if usage == nil && activity == nil { break }
            await usage?.value
            await activity?.value
        }
        guard lastPrefetchOpen == openedAt, account == usageAccount, interfaceStyle.current == .modern else { return }
        reloadConfig()
        guard account == usageAccount, let key = config?.apiKey else { return }
        expireHourlyResults()
        let current = currentQueryRange
        guard usageCache.lastReadSucceeded(for: current) else { return }
        var pending: [DashboardReads] = []
        for period in UsageFilterSummary.quickPeriods {
            let range = queryRange(for: period, at: usageNow())
            guard range != current else { continue }
            let pair = readModernRange(range, key: key, reuseFor: 300, display: false)
            if pair.usage != nil || pair.activity != nil { pending.append(pair) }
            // A custom period leaves five shortcuts. Read at most four per open.
            if pending.count == 4 { break }
        }
        for pair in pending {
            await pair.usage?.value
            await pair.activity?.value
        }
    }

    func fetchUsageData() async {
        guard !usesFixtureDashboard else { return }
        reloadConfig()
        guard isConfigured, let apiKey = config?.apiKey else { return }
        if interfaceStyle.current == .modern {
            expireHourlyResults()
            let reads = readModernRange(currentQueryRange, key: apiKey, reuseFor: 0, display: true)
            await reads.usage?.value
            return
        }
        if cacheDay != nil { clearRangeCaches() }
        usageFetchGeneration &+= 1
        let generation = usageFetchGeneration
        let queryRange = currentQueryRange
        attemptedUsageRange = queryRange
        startActivityFetch(range: queryRange, key: apiKey)
        isLoadingData = true
        defer {
            // An older request may finish after the user selects a new range.
            // Only the newest request owns the loading state and freshness marker.
            if generation == usageFetchGeneration {
                lastFetchTime = Date()
                hasLoadedUsageData = true
                isLoadingData = false
                usageReadsFinished &+= 1
            }
        }

        do {
            await waitForLaunchNetwork()
            guard generation == usageFetchGeneration, !Task.isCancelled else { return }
            let response = try await usageFetcher(usageServer, apiKey, queryRange)
            guard generation == usageFetchGeneration else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                buckets = response.buckets
                hasAnyData = response.hasAnyData
                loadedUsageRange = queryRange
                usageNames = response.names
            }
        } catch {
            guard generation == usageFetchGeneration else { return }
            // Silently fail — dashboard shows stale data or empty state
            print("Failed to fetch usage data: \(error)")
        }
    }

    /// The modern panel counts the same tools and terminals for every metric.
    /// The server computes the union and accepts no model parameter.
    private var activityFilters: FilterState {
        guard interfaceStyle.current == .modern else { return filters }
        let effective = modernPanel.usageFilters(filters, enabled: quotaCardProviders)
        return FilterState(sources: effective.sources, hostnames: effective.hostnames)
    }

    /// Hour periods for today and the rolling day; in the new panel also for
    /// a single custom day, whose curve is drawn by the hour (#105). The
    /// classic chart keeps one day there, so its request is unchanged.
    func activityIsHourly(_ range: UsageQueryRange) -> Bool {
        range.isHourly || interfaceStyle.current == .modern && range.isSingleCustomDay
    }

    private func startActivityFetch(range: UsageQueryRange, key: String) {
        activityTask?.cancel()
        if modernActivityTask != nil {
            activityCache.remove()
            modernActivityTask = nil
        }
        let filters = activityFilters
        let items = filters.activityQueryItems
        if activityRange != range || lastActivityFilterItems != items { activity = nil }
        activityRange = range
        lastActivityFilterItems = items
        let start = range.start(at: Date())
        let hourly = activityIsHourly(range)
        activityTask = Task { [weak self, server = usageServer] in
            guard let self else { return }
            await self.waitForLaunchNetwork()
            guard !Task.isCancelled else { return }
            let result = try? await self.activityFetcher(server, key, range, filters, hourly)
            guard !Task.isCancelled else { return }
            self.activity = result.map { ActivityReport($0, rangeStart: start, hourly: hourly) }
            self.activityTask = nil
        }
    }

    /// Fetch dashboard data unless we already fetched within the last 60s.
    /// Used by popover open to avoid hammering /api/usage on rapid open/close.
    func fetchUsageDataIfNeeded() async {
        if interfaceStyle.current == .modern {
            await openModernUsage()?.value
            return
        }
        // Opening the panel during the eager launch fetch must not start the
        // same request again. Explicit range changes call fetchUsageData()
        // directly and are still allowed to supersede the in-flight request.
        let recentlyFetched = lastFetchTime.map { Date().timeIntervalSince($0) < 60 } ?? false
        if !isLoadingData && !recentlyFetched {
            await fetchUsageData()
        }
    }

    /// Legacy provider-specific entry point retained for Settings bindings and
    /// tests. New UI should use `setQuotaProductSelected`.
    func setCodexRateLimitEnabled(_ enabled: Bool) async {
        await setQuotaProductSelected(.codex, selected: enabled)
    }

    /// Toggle Claude quota monitoring. Read-only like Codex — nothing to
    /// install, so the preference flips immediately.
    func setClaudeRateLimitEnabled(_ enabled: Bool) async {
        await setQuotaProductSelected(.claudeCode, selected: enabled)
    }

    /// Update the main-panel product list. Selection order is display order and
    /// is persisted independently from shared CLI config. Manual selection is
    /// never gated by imperfect local discovery, and nothing is ever evicted:
    /// the card row scrolls, so every enabled product keeps its card.
    func setQuotaProductSelected(
        _ provider: ProviderRateLimit.Provider,
        selected: Bool
    ) async {
        let wasSelected = isQuotaProviderSelected(provider)
        guard wasSelected != selected else { return }
        if selected {
            guard canSelectQuotaProvider(provider) else { return }
        }

        let previousSelection = selectedQuotaProviders
        updateQuotaSelection(provider: provider, selected: selected)
        let removedProviders = previousSelection.filter { !selectedQuotaProviders.contains($0) }
        for removedProvider in removedProviders {
            rateLimitCoordinator?.cancelRefresh(for: removedProvider)
            removeRateLimit(for: removedProvider)
        }

        if selected {
            if rateLimitCoordinator == nil { startRateLimitCoordinator() }
            rateLimitCoordinator?.seedPlaceholder(for: provider)
            await refreshRateLimit(for: provider)
        }
    }

    func isQuotaProviderSelected(_ provider: ProviderRateLimit.Provider) -> Bool {
        selectedQuotaProviders.contains(provider)
    }

    /// Tab strip order: products whose monitoring is on, then the rest — each
    /// group in the user's persisted order. A product the user turns off keeps
    /// its tab (greyed, after the enabled ones) instead of vanishing, so the
    /// strip never reflows just because a toggle changed.
    var quotaTabOrder: [ProviderRateLimit.Provider] {
        let order = quotaProductOrder.isEmpty ? quotaProducts.map(\.provider) : quotaProductOrder
        let known = Set(quotaProducts.map(\.provider))
        let catalog = order.filter { known.contains($0) }
            + quotaProducts.map(\.provider).filter { !order.contains($0) }
        return catalog.filter { isQuotaProviderSelected($0) }
            + catalog.filter { !isQuotaProviderSelected($0) }
    }

    /// Products that own a card: the enabled ones, in strip order. A product
    /// whose monitoring is off has no card at all — its grey tab leads to
    /// Settings instead — so an all-off selection leaves the section at the
    /// icon row.
    var quotaCardProviders: [ProviderRateLimit.Provider] {
        quotaTabOrder.filter { isQuotaProviderSelected($0) }
    }

    /// "Enabled, but not producing quota data" — the amber dot on a tab. True
    /// only for a product the user opted into, whose last read settled on
    /// something other than `.ok`, and which is not mid-refresh (a spinner is
    /// not a problem). A product with no snapshot yet says nothing.
    func quotaTabShowsWarning(_ provider: ProviderRateLimit.Provider) -> Bool {
        quotaWarningSnapshot(for: provider) != nil
    }

    /// The Settings row describes the very same snapshot that lights the tab.
    func quotaWarningSnapshot(for provider: ProviderRateLimit.Provider) -> ProviderRateLimit? {
        guard isQuotaProviderSelected(provider),
              !isRateLimitRefreshing(provider),
              let snapshot = rateLimits.first(where: { $0.provider == provider }),
              // Numbers kept on screen while the egress check pauses the
              // read still warn: they are not being refreshed.
              snapshot.status != .ok || snapshot.liveFailure?.isNetworkPause == true
        else { return nil }
        return snapshot
    }

    /// Switch the visible card. Selecting a tab never changes a product's
    /// monitoring state — enabling stays an explicit action (`启用` on the card
    /// or the toggle in Settings).
    func selectQuotaTab(_ provider: ProviderRateLimit.Provider) {
        guard quotaTabOrder.contains(provider), provider != selectedQuotaTab else { return }
        selectedQuotaTab = provider
        QuotaSelectionPreferences.persistSelectedTab(provider, defaults: quotaDefaults)
    }

    /// Drag-and-drop reorder. `target == nil` means "dropped past the last
    /// tab", which lands at the end of the dragged product's *own* group.
    /// The persisted array is kept in render order (enabled products first), so
    /// a cross-group drop normalizes back into the dragged product's group —
    /// the "enabled first" rule wins over the drop, and reading the stored
    /// order back always reproduces the strip.
    func moveQuotaProduct(
        _ provider: ProviderRateLimit.Provider,
        before target: ProviderRateLimit.Provider?
    ) {
        guard provider != target else { return }
        var order = quotaTabOrder
        guard let from = order.firstIndex(of: provider) else { return }
        order.remove(at: from)

        let destination: Int
        if let target, let to = order.firstIndex(of: target) {
            destination = to
        } else {
            // "Past the last tab" means the end of the dragged product's own
            // group — the slot right after that group's last member. Searching
            // for the *first* member of the other group instead would insert a
            // grey product at the start of the grey group, the opposite of
            // dropping it last.
            let isEnabled = isQuotaProviderSelected(provider)
            let lastSameGroup = order.lastIndex { isQuotaProviderSelected($0) == isEnabled }
            destination = lastSameGroup.map { $0 + 1 } ?? order.count
        }
        order.insert(provider, at: destination)
        applyQuotaProductOrder(order)
    }

    private func applyQuotaProductOrder(_ order: [ProviderRateLimit.Provider]) {
        quotaProductOrder = order
        QuotaSelectionPreferences.persistOrder(order, defaults: quotaDefaults)
    }

    func isRateLimitRefreshing(_ provider: ProviderRateLimit.Provider) -> Bool {
        switch provider {
        case .codex: return isCodexRateLimitRefreshing
        case .claudeCode: return isClaudeRateLimitRefreshing
        case .kimiCode, .zCode, .grok, .cursor, .antigravity: return cliQuotaRefreshingProviders.contains(provider)
        case .opencodeGo: return isOpenCodeGoRateLimitRefreshing
        }
    }

    func canSelectQuotaProvider(_ provider: ProviderRateLimit.Provider) -> Bool {
        if isQuotaProviderSelected(provider) { return true }
        // Discovery decides the first-launch defaults and the status copy, not
        // whether an explicit user click is accepted. This also gives users a
        // manual escape hatch when a tool lives in a non-standard directory.
        return quotaProducts.contains(where: { $0.provider == provider })
    }

    func quotaProductStatusText(_ product: QuotaProduct) -> String {
        guard product.provider == .zCode, product.availability == .ready else {
            return product.statusText
        }
        if !product.isDetected { return zCodeAPIKeyConfigured ? "未检测到 · API Key 已配置" : "未检测到" }
        return zCodeAPIKeyConfigured
            ? "已检测 · \(zCodeQuotaRegion.displayName) 已配置"
            : "需配置 \(zCodeQuotaRegion.apiKeyName)"
    }

    func zCodeAPIKeyForQuotaFetch() -> String? {
        try? zCodeAPIKeyStore.load(for: zCodeQuotaRegion)
    }

    func storeZCodeAPIKey(_ value: String?) throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try zCodeAPIKeyStore.store(trimmed.isEmpty ? nil : trimmed, for: zCodeQuotaRegion)
        // A saved value identifies the account behind every ZCode snapshot.
        // Never retain or publish work from the previous Key after replacement.
        rateLimitCoordinator?.zCodeCredentialContextDidChange()
        removeRateLimit(for: .zCode)
        zCodeAPIKeyConfigured = !trimmed.isEmpty
        if trimmed.isEmpty, isQuotaProviderSelected(.zCode) {
            updateQuotaSelection(provider: .zCode, selected: false)
        }
    }

    /// Arriving in Settings on the Cursor row opens its sign-in block only
    /// when a sign-in is what is missing: the last Cursor read said so, or the
    /// sign-in Vibe Usage keeps has ended. Users whose own Cursor login still
    /// reads are not pushed toward signing in.
    var cursorSignInNeeded: Bool {
        guard cursorLogin.isAvailable else { return false }
        if cursorLogin.phase.isExpired { return true }
        guard cursorLogin.phase == .signedOut else { return false }
        return rateLimits.first(where: { $0.provider == .cursor })?.liveFailure?.isCursorSignIn == true
    }

    /// The user signed in to Cursor in Settings, or out: the Cursor card's
    /// numbers belonged to the previous state, so it is read again; a new
    /// sign-in also syncs at once so Cursor's paused history fills in.
    func cursorSignInDidChange(signedIn: Bool) async {
        rateLimitCoordinator?.cursorCredentialContextDidChange()
        removeRateLimit(for: .cursor)
        if signedIn, isConfigured {
            Task { await self.triggerSync() }
        }
        guard isQuotaProviderSelected(.cursor) else { return }
        rateLimitCoordinator?.seedPlaceholder(for: .cursor)
        await refreshRateLimit(for: .cursor)
    }

    /// Switches the ZCode account region without moving or sharing secrets
    /// between regional Keychain items. A configured target refreshes in place;
    /// an unconfigured target releases its selection slot until a key is saved.
    func setZCodeQuotaRegion(_ region: ZCodeQuotaRegion) async {
        guard region != zCodeQuotaRegion else { return }
        let wasSelected = isQuotaProviderSelected(.zCode)
        rateLimitCoordinator?.zCodeCredentialContextDidChange()
        removeRateLimit(for: .zCode)

        zCodeQuotaRegion = region
        quotaDefaults.set(region.rawValue, forKey: ZCodeQuotaRegion.defaultsKey)
        zCodeAPIKeyConfigured = (try? zCodeAPIKeyStore.load(for: region)) != nil

        if wasSelected, !zCodeAPIKeyConfigured {
            updateQuotaSelection(provider: .zCode, selected: false)
        } else if wasSelected {
            rateLimitCoordinator?.seedPlaceholder(for: .zCode)
            await refreshRateLimit(for: .zCode)
        }
    }

    /// Re-run only the local filesystem checks. Newly found products are never
    /// added to the user's selection automatically after initialization.
    func rediscoverQuotaProducts() {
        quotaProducts = QuotaProductRegistry.discover()
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        TestDiagnosticLog.recordQuotaProductsDiscovered(
            quotaProducts.filter(\.isDetected).map(\.provider)
        )
        #endif
    }

    /// Refresh Codex rate limits unconditionally. Safe — no keychain prompts.
    /// Used by the manual "更新数据" / retry paths.
    func refreshCodexRateLimit() async {
        guard codexRateLimitEnabled else { return }
        await rateLimitCoordinator?.refreshCodex()
    }

    /// Refresh exactly one provider. Card-level retry routes through this
    /// provider-keyed command so adding another provider does not require a new
    /// view-facing AppState method or duplicated retry logic.
    func refreshRateLimit(for provider: ProviderRateLimit.Provider) async {
        switch provider {
        case .codex:
            guard codexRateLimitEnabled else { return }
            await rateLimitCoordinator?.refreshCodex()
        case .claudeCode:
            guard claudeRateLimitEnabled else { return }
            await rateLimitCoordinator?.refreshClaude()
        case .kimiCode, .zCode, .grok, .cursor, .antigravity:
            guard isQuotaProviderSelected(provider) else { return }
            await rateLimitCoordinator?.refreshCLIProviders([provider])
        case .opencodeGo:
            guard isQuotaProviderSelected(provider) else { return }
            await rateLimitCoordinator?.refreshOpenCodeGo()
        }
    }

    /// Refresh Codex rate limits only if the last fetch was over a minute ago.
    /// Used by popover-open so toggling the menu bar doesn't re-walk the
    /// Codex session tree on every click.
    func refreshCodexRateLimitIfNeeded() async {
        guard codexRateLimitEnabled else { return }
        await rateLimitCoordinator?.refreshCodexIfNeeded()
    }

    /// Refresh Claude rate limits on popover-open (debounced). Prompt-free: the
    /// probe delegates to a Claude Code binary, which reads its own credentials.
    func refreshClaudeRateLimitIfNeeded() async {
        guard claudeRateLimitEnabled else { return }
        await rateLimitCoordinator?.refreshClaudeIfNeeded()
    }

    /// Refresh both Codex and Claude (in parallel). Prompt-free: Codex hits the
    /// zero-quota usage endpoint with the CLI's own token, Claude reads the
    /// local cache then delegates the live read to Claude Code. Safe to call
    /// from the global user-initiated refresh path.
    func refreshAllRateLimits() async {
        await rateLimitCoordinator?.refreshAll()
    }

    /// Popover-open path for all selected products. Today the coordinator owns
    /// native Codex/Claude adapters; its generic boundary prevents views from
    /// learning that implementation detail.
    func refreshSelectedRateLimitsIfNeeded() async {
        await rateLimitCoordinator?.refreshSelectedIfNeeded()
    }

    /// The new panel's 「刷新额度」: quotas only, never a usage sync. While any
    /// read in the scope is still running (the button spins) a click does
    /// nothing: on 概览 a second `refreshAll()` would read again the
    /// providers that already answered.
    func refreshQuotas(_ scope: QuotaRefreshScope) async {
        guard !isRefreshingQuotas(scope) else { return }
        switch scope {
        case .all: await refreshAllRateLimits()
        case .one(let provider): await refreshRateLimit(for: provider)
        }
    }

    /// Spinner state of 「刷新额度」 for that scope.
    func isRefreshingQuotas(_ scope: QuotaRefreshScope) -> Bool {
        switch scope {
        case .all: quotaCardProviders.contains(where: isRateLimitRefreshing)
        case .one(let provider): isRateLimitRefreshing(provider)
        }
    }

    /// A real open of the menu-bar panel (both styles). Puts the new panel
    /// back on 概览, then does what an open always did: fetch usage unless it
    /// is under a minute old, and read the selected quotas on their usual
    /// interval — never a forced quota read or a sync. The returned task ends
    /// when both reads have; callers may ignore it.
    @discardableResult
    func panelWillOpen() -> Task<Void, Never> {
        modernPanel.panelDidOpen()
        let usage = interfaceStyle.current == .modern ? openModernUsage() : Task { await fetchUsageDataIfNeeded() }
        // The coordinator applies a per-provider interval, so rapid
        // open/close stays cheap.
        let quotas = Task { await refreshSelectedRateLimitsIfNeeded() }
        rateLimitPanelVisibilityChanged(visible: true)
        return Task {
            await usage?.value
            await quotas.value
        }
    }

    /// The menu-bar panel opened or closed. Closing cancels in-flight refreshes
    /// for both providers — nothing off-screen is worth a round trip.
    func rateLimitPanelVisibilityChanged(visible: Bool) {
        isPanelVisible = visible
        rateLimitCoordinator?.panelVisibilityChanged(visible: visible)
    }


    #if DEBUG
    /// Two buckets in the current hour totalling $230.20 and 364.1M Token.
    /// Debug-only preview data behind `VIBE_USAGE_SAMPLE_USAGE`.
    static func sampleUsageBuckets(now: Date = Date()) -> [UsageBucket] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let start = ISO8601DateFormatter().string(from: hour)
        return [
            UsageBucket(
                source: "claude-code", model: "claude-opus-5-5", project: "vibe-usage-app", hostname: "preview",
                bucketStart: start, inputTokens: 2_100_000, outputTokens: 900_000,
                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                cachedInputTokens: 260_000_000, reasoningOutputTokens: 0, totalTokens: 263_000_000, estimatedCost: 180.15
            ),
            UsageBucket(
                source: "codex", model: "gpt-6.2-sol", project: "vibe-usage", hostname: "preview",
                bucketStart: start, inputTokens: 1_500_000, outputTokens: 600_000,
                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                cachedInputTokens: 99_000_000, reasoningOutputTokens: 0, totalTokens: 101_100_000, estimatedCost: 50.05
            ),
        ]
    }
    #endif

    // MARK: - Private

    private func removeRateLimit(for provider: ProviderRateLimit.Provider) {
        rateLimits.removeAll { $0.provider == provider }
    }

    private func updateQuotaSelection(
        provider: ProviderRateLimit.Provider,
        selected: Bool
    ) {
        let next = QuotaSelectionPreferences.updating(
            selectedQuotaProviders,
            provider: provider,
            selected: selected
        )
        guard next != selectedQuotaProviders else { return }
        selectedQuotaProviders = next
        QuotaSelectionPreferences.persist(next, defaults: quotaDefaults)
        quotaDefaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        TestDiagnosticLog.recordQuotaSelectionChanged(next)
        #endif
    }

    func startRateLimitCoordinator() {
        let coord = makeRateLimitCoordinator(self)
        coord.seedPlaceholders()
        self.rateLimitCoordinator = coord
        // Preserve panel state even when the coordinator is created lazily
        // after the panel opened (for example, both providers started off).
        coord.panelVisibilityChanged(visible: isPanelVisible)
    }

    /// Set by the app delegate for a login-item launch (`LoginLaunch`), before
    /// `initialize()`: network reads then wait for the user's proxy.
    var launchWaitsForProxy = false
    /// That wait, started once by `initialize()`; nil for any other launch.
    @ObservationIgnored var launchProxyWait: Task<Void, Never>?

    /// Returns once a login launch's proxy is up or its wait ran out; at once
    /// for any other launch. Sync, dashboard and live quota reads share it.
    func waitForLaunchNetwork() async {
        await launchProxyWait?.value
    }

    /// The URL whose route decides whether the user's proxy is up: the server
    /// the CLI syncs to.
    nonisolated static func launchProbeURL(apiURL: String? = ConfigManager.load()?.apiUrl) -> URL {
        UsageServer(apiURL).siteURL ?? URL(string: AppConfig.defaultApiUrl)!
    }
    /// The launch sync, cancelled when the scheduler is started again
    /// (relink) or the configuration is reset.
    private var launchSyncTask: Task<Void, Never>?

    private func startScheduler() {
        syncScheduler = SyncScheduler(interval: Self.syncInterval) { [weak self] in
            await self?.triggerSync(.scheduled)
        }
        syncScheduler?.start()

        // Start the dashboard in parallel with sync. Both wait for a login
        // launch's proxy, but the menu bar need not wait for the CLI subprocess.
        Task { await fetchUsageData() }
        // Run the full sync (CLI upload + fetch) in parallel as the background
        // pipeline; a login launch waits for the user's proxy first.
        launchSyncTask?.cancel()
        launchSyncTask = Task {
            await waitForLaunchNetwork()
            guard !Task.isCancelled else { return }
            await triggerSync(.launch)
        }
    }

    // MARK: - Diagnostics

    static let syncInterval: TimeInterval = 1800

    /// Whether the 30-minute timer is running (it starts once a Key exists).
    var isSyncSchedulerRunning: Bool { syncScheduler != nil }

    /// The app's own record of recent syncs, newest first (at most 10).
    var syncHistory: SyncHistoryStore { SyncHistoryStore(defaults: quotaDefaults) }
}
