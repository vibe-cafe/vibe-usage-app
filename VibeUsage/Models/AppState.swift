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

    // MARK: - Rate Limits (subscription quota for Claude + Codex)
    var codexRateLimitEnabled: Bool = true {
        didSet { UserDefaults.standard.set(codexRateLimitEnabled, forKey: "codexRateLimitEnabled") }
    }
    var rateLimits: [ProviderRateLimit] = []

    /// True while the corresponding provider's refresh is in flight — the card
    /// header shows a mini spinner. Codex refreshes now include a network
    /// round-trip (~1s), so unlike the old file-only reads the latency is
    /// user-perceivable and needs an indicator.
    var isCodexRateLimitRefreshing: Bool = false
    var isClaudeRateLimitRefreshing: Bool = false

    /// Enabling Claude rate-limit monitoring installs a wrapper into Claude
    /// Code's `statusLine.command` (see `StatuslineHook`). Because that edits
    /// the user's Claude settings, we gate it behind an explicit opt-in click.
    /// Persisted across launches. Once enabled, reads are auth-free local-file
    /// reads — no keychain, no network.
    var claudeRateLimitEnabled: Bool = false {
        didSet { UserDefaults.standard.set(claudeRateLimitEnabled, forKey: "claudeRateLimitEnabled") }
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
    private var config: VibeUsageConfig?

    // MARK: - Lifecycle

    func initialize() {
        // Load menu bar prefs
        self.showCostInMenuBar = UserDefaults.standard.object(forKey: "showCostInMenuBar") as? Bool ?? true
        self.showTokensInMenuBar = UserDefaults.standard.object(forKey: "showTokensInMenuBar") as? Bool ?? false
        self.showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        let legacyRateLimitEnabled = UserDefaults.standard.object(forKey: "rateLimitMonitoringEnabled") as? Bool
        self.codexRateLimitEnabled = UserDefaults.standard.object(forKey: "codexRateLimitEnabled") as? Bool ?? legacyRateLimitEnabled ?? true
        self.claudeRateLimitEnabled = UserDefaults.standard.bool(forKey: "claudeRateLimitEnabled")

        // Self-heal only while Claude monitoring is enabled. When disabled,
        // restore Claude Code's statusline command and keep that provider idle.
        if claudeRateLimitEnabled {
            StatuslineHook.verifyAndRepair(enabled: true)
        } else {
            _ = StatuslineHook.uninstall()
        }

        let loadedConfig = ConfigManager.load()
        self.config = loadedConfig
        self.isConfigured = loadedConfig?.apiKey != nil

        let runtime = RuntimeDetector.detect()
        self.runtimeAvailable = runtime != nil

        if isConfigured {
            startScheduler()
        }

        // Rate limits are independent of configuration — both Codex and Claude
        // read local files (no auth). Start only for enabled providers.
        if codexRateLimitEnabled || claudeRateLimitEnabled {
            startRateLimitCoordinator()
        }
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
        guard !isLoadingData else { return }
        isLoadingData = true
        defer {
            lastFetchTime = Date()
            hasLoadedUsageData = true
            isLoadingData = false
        }

        let apiUrl = config.apiUrl ?? AppConfig.defaultApiUrl
        let client = APIClient(baseURL: apiUrl, apiKey: apiKey)

        do {
            let response = try await client.fetchUsage(range: currentQueryRange)
            withAnimation(.easeInOut(duration: 0.25)) {
                buckets = response.buckets
                sessions = response.sessions ?? []
                hasAnyData = response.hasAnyData
            }
        } catch {
            // Silently fail — dashboard shows stale data or empty state
            print("Failed to fetch usage data: \(error)")
        }
    }

    /// Fetch dashboard data unless we already fetched within the last 60s.
    /// Used by popover open to avoid hammering /api/usage on rapid open/close.
    func fetchUsageDataIfNeeded() async {
        if let last = lastFetchTime, Date().timeIntervalSince(last) < 60 {
            return
        }
        await fetchUsageData()
    }

    /// Toggle Codex quota monitoring. Codex is read-only, so disabling just
    /// stops scans and hides its snapshot.
    func setCodexRateLimitEnabled(_ enabled: Bool) async {
        guard codexRateLimitEnabled != enabled else { return }
        codexRateLimitEnabled = enabled

        if enabled {
            if rateLimitCoordinator == nil { startRateLimitCoordinator() }
            await refreshCodexRateLimit()
        } else {
            removeRateLimit(for: .codex)
        }
    }

    /// Toggle Claude quota monitoring. Only flips persisted state after the
    /// hook operation succeeds; failures leave the toggle reflecting reality.
    func setClaudeRateLimitEnabled(_ enabled: Bool) async {
        guard claudeRateLimitEnabled != enabled else { return }
        claudeRateLimitInstallError = nil

        if enabled {
            if rateLimitCoordinator == nil { startRateLimitCoordinator() }
            await enableClaudeRateLimit()
        } else {
            switch StatuslineHook.uninstall() {
            case .success:
                claudeRateLimitEnabled = false
                removeRateLimit(for: .claudeCode)
                debugLog("[rate-limit] statusline hook uninstalled; original command restored")
            case .failure(let error):
                debugLog("[rate-limit] statusline uninstall failed: \(error)")
                claudeRateLimitInstallError = error.localizedDescription
            }
        }
    }

    /// Refresh Codex rate limits unconditionally. Safe — no keychain prompts.
    /// Used by the manual "更新数据" / retry paths.
    func refreshCodexRateLimit() async {
        guard codexRateLimitEnabled else { return }
        await rateLimitCoordinator?.refreshCodex()
    }

    /// Refresh Codex rate limits only if the last fetch was over a minute ago.
    /// Used by popover-open so toggling the menu bar doesn't re-walk the
    /// Codex session tree on every click.
    func refreshCodexRateLimitIfNeeded() async {
        guard codexRateLimitEnabled else { return }
        await rateLimitCoordinator?.refreshCodexIfNeeded()
    }

    /// Refresh Claude rate limits on popover-open (debounced). Cheap local-file
    /// read now — safe to fire automatically, no prompts.
    func refreshClaudeRateLimitIfNeeded() async {
        guard claudeRateLimitEnabled else { return }
        await rateLimitCoordinator?.refreshClaudeIfNeeded()
    }

    /// Refresh both Codex and Claude (in parallel). Prompt-free: Codex hits the
    /// zero-quota usage endpoint with the CLI's own token, Claude reads the
    /// local capture file. Safe to call from any user-initiated path.
    func refreshAllRateLimits() async {
        await rateLimitCoordinator?.refreshAll()
    }

    /// The menu-bar panel opened or closed. While it is visible the coordinator
    /// watches the Claude capture directory so a statusline render updates the
    /// card live; closing stops the watcher (nothing to update off-screen).
    func rateLimitPanelVisibilityChanged(visible: Bool) {
        rateLimitCoordinator?.panelVisibilityChanged(visible: visible)
    }

    /// Enable Claude rate-limit monitoring: install the statusline wrapper into
    /// Claude Code's settings, then read whatever it has captured so far.
    /// Surfaces an install failure via the Claude card's error state.
    ///
    /// On a *fresh* enable the capture file doesn't exist yet — Claude Code only
    /// writes it on its next statusline render (typically within ~1s of any
    /// activity). So after a successful install we poll briefly and re-read, so
    /// a single 启用 click populates the card on its own instead of leaving it
    /// stuck on "disabled" until the user pokes it again.
    func enableClaudeRateLimit() async {
        debugLog("[rate-limit] enableClaudeRateLimit() called")
        switch StatuslineHook.install() {
        case .success:
            claudeRateLimitInstallError = nil
            claudeRateLimitEnabled = true
            await rateLimitCoordinator?.refreshClaude()
            debugLog("[rate-limit] statusline hook installed; Claude capture enabled")

            // Card is .disabled/.noData until Claude Code renders a statusline
            // and the wrapper writes the file. Poll up to ~6s; stop early once
            // a real snapshot lands. No-op if it was already captured.
            for attempt in 1...6 {
                if claudeRateLimitSnapshot?.status == .ok { break }
                try? await Task.sleep(for: .seconds(1))
                debugLog("[rate-limit] post-install poll attempt \(attempt)")
                await rateLimitCoordinator?.refreshClaude()
            }
        case .failure(let error):
            debugLog("[rate-limit] statusline install failed: \(error)")
            claudeRateLimitInstallError = error.localizedDescription
        }
    }

    /// Current Claude snapshot in `rateLimits` (nil before the first read).
    private var claudeRateLimitSnapshot: ProviderRateLimit? {
        rateLimits.first { $0.provider == .claudeCode }
    }

    /// Last statusline-install failure message, surfaced in the Claude card.
    /// Cleared on the next successful enable.
    var claudeRateLimitInstallError: String?

    // MARK: - Private

    private func removeRateLimit(for provider: ProviderRateLimit.Provider) {
        rateLimits.removeAll { $0.provider == provider }
    }

    private func startRateLimitCoordinator() {
        let coord = RateLimitCoordinator(appState: self)
        coord.seedPlaceholders()
        // No background loop — Codex refreshes on popover open (debounced),
        // Claude only on user-initiated actions.
        self.rateLimitCoordinator = coord
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
