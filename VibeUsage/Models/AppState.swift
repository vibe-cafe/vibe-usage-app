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

    /// Trend chart bucket granularity. Hour-granularity for both today and the
    /// rolling 24h; day-granularity for the longer ranges.
    var isHourly: Bool { self == .today || self == .oneDay }

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
    // MARK: - Sync State
    var syncStatus: SyncStatus = .idle
    var lastSyncTime: Date?
    var lastSyncMessage: String?
    private var lastFetchTime: Date?

    // MARK: - Dashboard Data
    var buckets: [UsageBucket] = []
    var sessions: [UsageSession] = []
    var hasAnyData: Bool = false
    var isLoadingData: Bool = false
    var hasLoadedUsageData: Bool = false
    private var usageFetchGeneration: UInt = 0

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
    var filters: FilterState = .init()

    var currentQueryRange: UsageQueryRange {
        switch timeRange {
        case .today:
            return .from(Calendar.current.startOfDay(for: Date()))
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

    var filteredSessions: [UsageSession] {
        let cutoff = timeRange.startCutoff
        return sessions.filter { session in
            if let cutoff, let date = session.date, date < cutoff { return false }
            let f = filters
            if !f.sources.isEmpty && !f.sources.contains(session.source) { return false }
            if !f.projects.isEmpty && !f.projects.contains(session.project) { return false }
            if !f.hostnames.isEmpty && !f.hostnames.contains(session.hostname) { return false }
            return true
        }
    }

    // MARK: - Config
    var isConfigured: Bool = false
    var runtimeAvailable: Bool = true

    // MARK: - Subscription Quotas
    private(set) var quotaProducts: [QuotaProduct] = QuotaProductRegistry.catalog.map {
        QuotaProduct(provider: $0.0, availability: $0.1, isDetected: false)
    }
    private(set) var selectedQuotaProviders: [ProviderRateLimit.Provider] = [.codex, .claudeCode]
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
    private var isRateLimitPanelVisible = false
    private var config: VibeUsageConfig?
    private let usageFetcher: (String, String, UsageQueryRange) async throws -> UsageResponse
    private let quotaDefaults: UserDefaults
    private let zCodeAPIKeyStore: any ZCodeAPIKeyStoring
    private let quotaProductDiscoverer: () -> [QuotaProduct]

    init(
        initialConfig: VibeUsageConfig? = nil,
        usageFetcher: @escaping (String, String, UsageQueryRange) async throws -> UsageResponse = { apiUrl, apiKey, range in
            try await APIClient(baseURL: apiUrl, apiKey: apiKey).fetchUsage(range: range)
        },
        quotaDefaults: UserDefaults = .standard,
        zCodeAPIKeyStore: any ZCodeAPIKeyStoring = KeychainZCodeAPIKeyStore(),
        quotaProductDiscoverer: @escaping () -> [QuotaProduct] = {
            QuotaProductRegistry.discover()
        }
    ) {
        self.config = initialConfig
        self.isConfigured = initialConfig?.apiKey != nil
        self.usageFetcher = usageFetcher
        self.quotaDefaults = quotaDefaults
        self.zCodeAPIKeyStore = zCodeAPIKeyStore
        self.quotaProductDiscoverer = quotaProductDiscoverer
    }

    // MARK: - Lifecycle

    func initialize() {
        // Load menu bar prefs
        self.showCostInMenuBar = UserDefaults.standard.object(forKey: "showCostInMenuBar") as? Bool ?? true
        self.showTokensInMenuBar = UserDefaults.standard.object(forKey: "showTokensInMenuBar") as? Bool ?? false
        self.showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        initializeQuotaProducts()
        self.claudeUsesDesktopBundledCLI = ClaudeUsageProbe.primarySourceKind() == .desktop

        #if DEBUG
        // UI acceptance builds can exercise subscription cards without
        // reading a production Vibe account config or starting its sync/upload
        // scheduler. The environment hook is compiled out of Release.
        if ProcessInfo.processInfo.environment["VIBE_USAGE_QUOTA_UI_TEST"] == "1" {
            self.isConfigured = true
            self.hasLoadedUsageData = true
            if !selectedQuotaProviders.isEmpty {
                startRateLimitCoordinator()
            }
            return
        }
        #endif

        // Hand back the `statusLine.command` edit the pre-probe releases made.
        LegacyStatuslineRetirement.run()

        let loadedConfig = ConfigManager.load()
        self.config = loadedConfig
        self.isConfigured = loadedConfig?.apiKey != nil

        let runtime = RuntimeDetector.detect()
        self.runtimeAvailable = runtime != nil

        if isConfigured {
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

    /// Save config to disk and start scheduler.
    func configure(apiKey: String, apiUrl: String = AppConfig.defaultApiUrl) {
        var cfg = ConfigManager.load() ?? VibeUsageConfig()
        cfg.apiKey = apiKey
        cfg.apiUrl = apiUrl
        ConfigManager.save(cfg)

        self.config = ConfigManager.load()
        self.isConfigured = self.config?.apiKey != nil
        if isConfigured {
            startScheduler()
        }
    }

    // MARK: - Sync

    func triggerSync() async {
        guard syncStatus != .syncing else { return }
        syncStatus = .syncing

        let result = await SyncEngine.shared.runSync()

        switch result {
        case .success(let message):
            syncStatus = .success
            lastSyncTime = Date()
            lastSyncMessage = message
            // Refresh dashboard data after sync
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

    // MARK: - Data Fetching

    func fetchUsageData() async {
        guard let config, let apiKey = config.apiKey else { return }

        usageFetchGeneration &+= 1
        let generation = usageFetchGeneration
        let queryRange = currentQueryRange
        isLoadingData = true
        defer {
            // An older request may finish after the user selects a new range.
            // Only the newest request owns the loading state and freshness marker.
            if generation == usageFetchGeneration {
                lastFetchTime = Date()
                hasLoadedUsageData = true
                isLoadingData = false
            }
        }

        let apiUrl = config.apiUrl ?? AppConfig.defaultApiUrl

        do {
            let response = try await usageFetcher(apiUrl, apiKey, queryRange)
            guard generation == usageFetchGeneration else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                buckets = response.buckets
                sessions = response.sessions ?? []
                hasAnyData = response.hasAnyData
            }
        } catch {
            guard generation == usageFetchGeneration else { return }
            // Silently fail — dashboard shows stale data or empty state
            print("Failed to fetch usage data: \(error)")
        }
    }

    /// Fetch dashboard data unless we already fetched within the last 60s.
    /// Used by popover open to avoid hammering /api/usage on rapid open/close.
    func fetchUsageDataIfNeeded() async {
        // Opening the panel during the eager launch fetch must not start the
        // same request again. Explicit range changes call fetchUsageData()
        // directly and are still allowed to supersede the in-flight request.
        guard !isLoadingData else { return }
        if let last = lastFetchTime, Date().timeIntervalSince(last) < 60 {
            return
        }
        await fetchUsageData()
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
            let isEnabled = isQuotaProviderSelected(provider)
            destination = order.firstIndex { isQuotaProviderSelected($0) != isEnabled } ?? order.count
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
        case .kimiCode, .zCode, .grok: return cliQuotaRefreshingProviders.contains(provider)
        case .opencodeGo: return isOpenCodeGoRateLimitRefreshing
        case .cursor: return false
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
        case .kimiCode, .zCode, .grok:
            guard isQuotaProviderSelected(provider) else { return }
            await rateLimitCoordinator?.refreshCLIProviders([provider])
        case .opencodeGo:
            guard isQuotaProviderSelected(provider) else { return }
            await rateLimitCoordinator?.refreshOpenCodeGo()
        case .cursor: return
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

    /// The menu-bar panel opened or closed. Closing cancels in-flight refreshes
    /// for both providers — nothing off-screen is worth a round trip.
    func rateLimitPanelVisibilityChanged(visible: Bool) {
        isRateLimitPanelVisible = visible
        rateLimitCoordinator?.panelVisibilityChanged(visible: visible)
    }

    /// True when Claude quota is read through the copy of Claude Code that
    /// Claude Desktop bundles, i.e. this machine has Desktop but no CLI of its
    /// own. Settings calls that out, because it is the one case where the data
    /// comes from somewhere the user did not install directly. With a CLI
    /// present there is nothing to explain, so the note stays hidden.
    ///
    /// Resolved once at launch: it depends only on which binaries exist on
    /// disk, and re-scanning on every Settings redraw would buy nothing.
    private(set) var claudeUsesDesktopBundledCLI = false

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

    private func startRateLimitCoordinator() {
        let coord = RateLimitCoordinator(appState: self)
        coord.seedPlaceholders()
        self.rateLimitCoordinator = coord
        // Preserve panel state even when the coordinator is created lazily
        // after the panel opened (for example, both providers started off).
        coord.panelVisibilityChanged(visible: isRateLimitPanelVisible)
    }

    private func startScheduler() {
        syncScheduler = SyncScheduler(interval: 1800) { [weak self] in
            await self?.triggerSync()
        }
        syncScheduler?.start()

        // Fetch the dashboard immediately so the menu bar populates without waiting for
        // the CLI subprocess (which can take 5-30s, or hang if Node isn't installed).
        Task { await fetchUsageData() }
        // Run the full sync (CLI upload + fetch) in parallel as the background pipeline.
        Task { await triggerSync() }
    }
}
