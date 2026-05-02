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
    case oneDay = "1D"
    case sevenDays = "7D"
    case thirtyDays = "30D"

    var days: Int {
        switch self {
        case .oneDay: 1
        case .sevenDays: 7
        case .thirtyDays: 30
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
        sessions.filter { session in
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

    /// Claude rate limit reads cross the keychain boundary, so we gate the first
    /// fetch on an explicit user click. Persisted across launches.
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

    // MARK: - Menu Bar Stats (matches current time range, no filters)
    var menuBarCost: Double {
        buckets.reduce(0) { $0 + ($1.estimatedCost ?? 0) }
    }

    var menuBarTokens: Int {
        buckets.reduce(0) { $0 + $1.computedTotal + $1.cachedInputTokens }
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

        let loadedConfig = ConfigManager.load()
        self.config = loadedConfig
        self.isConfigured = loadedConfig?.apiKey != nil

        let runtime = RuntimeDetector.detect()
        self.runtimeAvailable = runtime != nil

        if isConfigured {
            startScheduler()
        }

        // Rate limits are independent of configuration — Codex reads local files,
        // Claude reads its own OAuth token. Start regardless.
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

    /// Refresh only Codex rate limits. Safe — no keychain prompts.
    /// Used by popover-open and the periodic background timer.
    func refreshCodexRateLimit() async {
        await rateLimitCoordinator?.refreshCodex()
    }

    /// Refresh both Codex and Claude. Touches keychain — only call from
    /// user-initiated paths (footer 更新数据 button, retry buttons).
    func refreshAllRateLimits() async {
        await rateLimitCoordinator?.refreshAll()
    }

    /// Enable Claude rate-limit monitoring and trigger the first fetch.
    /// The fetch is what surfaces the macOS keychain access prompt — never auto-fired.
    func enableClaudeRateLimit() async {
        print("[rate-limit] enableClaudeRateLimit() called, coordinator=\(rateLimitCoordinator != nil ? "present" : "nil")")
        claudeRateLimitEnabled = true
        await rateLimitCoordinator?.refreshClaude()
        print("[rate-limit] enableClaudeRateLimit() completed")
    }

    // MARK: - Private

    private func startRateLimitCoordinator() {
        let coord = RateLimitCoordinator(appState: self)
        coord.seedPlaceholders()
        coord.start()
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
