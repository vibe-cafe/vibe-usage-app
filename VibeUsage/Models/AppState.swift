import Foundation
import SwiftUI
import VibeUsageCore

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

    /// How many days to request from the backend. `.today` re-uses the same
    /// `days=1` fetch as `.oneDay`; the today-cutoff is then applied
    /// client-side (see `startCutoff`) so callers don't need a separate API.
    var days: Int {
        switch self {
        case .today, .oneDay: 1
        case .sevenDays: 7
        case .thirtyDays: 30
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

    // MARK: - Dashboard Controls
    var timeRange: TimeRange = .oneDay
    var chartMode: ChartMode = .token
    var filters: FilterState = .init()

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
    var rateLimits: [ProviderRateLimit] = []

    /// Enabling Claude rate-limit monitoring installs a wrapper into Claude
    /// Code's `statusLine.command` (see `StatuslineHook`). Because that edits
    /// the user's Claude settings, we gate it behind an explicit opt-in click.
    /// Persisted across launches. Once enabled, reads are auth-free local-file
    /// reads — no keychain, no network.
    var claudeRateLimitEnabled: Bool = false {
        didSet { UserDefaults.standard.set(claudeRateLimitEnabled, forKey: "claudeRateLimitEnabled") }
    }

    // MARK: - Appearance
    var appTheme: AppTheme = .dark {
        didSet { appTheme.save() }
    }

    // MARK: - Menu Bar Display Prefs
    var showCostInMenuBar: Bool = true {
        didSet { UserDefaults.standard.set(showCostInMenuBar, forKey: "showCostInMenuBar") }
    }
    var showTokensInMenuBar: Bool = false {
        didSet { UserDefaults.standard.set(showTokensInMenuBar, forKey: "showTokensInMenuBar") }
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
        menuBarBuckets.reduce(0) { $0 + $1.computedTotal + $1.cachedInputTokens }
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
        self.claudeRateLimitEnabled = UserDefaults.standard.bool(forKey: "claudeRateLimitEnabled")
        self.appTheme = AppTheme.load()

        // Self-heal: if capture was enabled but a claude-hud upgrade or
        // `/statusline` clobbered our wrapper, silently re-assert it.
        StatuslineHook.verifyAndRepair(enabled: claudeRateLimitEnabled)

        let loadedConfig = ConfigManager.load()
        self.config = loadedConfig
        self.isConfigured = loadedConfig?.apiKey != nil

        let runtime = RuntimeDetector.detect()
        self.runtimeAvailable = runtime != nil

        if isConfigured {
            startScheduler()
        }

        // Rate limits are independent of configuration — both Codex and Claude
        // read local files (no auth). Start regardless.
        startRateLimitCoordinator()
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
        isLoadingData = true

        let apiUrl = config.apiUrl ?? AppConfig.defaultApiUrl
        let client = APIClient(baseURL: apiUrl, apiKey: apiKey)

        do {
            let response = try await client.fetchUsage(days: timeRange.days)
            buckets = response.buckets
            sessions = response.sessions ?? []
            hasAnyData = response.hasAnyData
        } catch {
            // Silently fail — dashboard shows stale data or empty state
            print("Failed to fetch usage data: \(error)")
        }

        lastFetchTime = Date()
        isLoadingData = false
    }

    /// Fetch dashboard data unless we already fetched within the last 60s.
    /// Used by popover open to avoid hammering /api/usage on rapid open/close.
    func fetchUsageDataIfNeeded() async {
        if let last = lastFetchTime, Date().timeIntervalSince(last) < 60 {
            return
        }
        await fetchUsageData()
    }

    /// Refresh Codex rate limits unconditionally. Safe — no keychain prompts.
    /// Used by the manual "更新数据" / retry paths.
    func refreshCodexRateLimit() async {
        await rateLimitCoordinator?.refreshCodex()
    }

    /// Refresh Codex rate limits only if the last fetch was over a minute ago.
    /// Used by popover-open so toggling the menu bar doesn't re-walk the
    /// Codex session tree on every click.
    func refreshCodexRateLimitIfNeeded() async {
        await rateLimitCoordinator?.refreshCodexIfNeeded()
    }

    /// Refresh Claude rate limits on popover-open (debounced). Cheap local-file
    /// read now — safe to fire automatically, no prompts.
    func refreshClaudeRateLimitIfNeeded() async {
        await rateLimitCoordinator?.refreshClaudeIfNeeded()
    }

    /// Refresh both Codex and Claude. Both are auth-free local-file reads now,
    /// so this is cheap and safe to call from any user-initiated path.
    func refreshAllRateLimits() async {
        await rateLimitCoordinator?.refreshAll()
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
