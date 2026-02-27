import Foundation
import SwiftUI

/// Sync status for menu bar icon display
enum SyncStatus: Equatable {
    case idle
    case syncing
    case success
    case error(String)
}

/// Time range selection for dashboard
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

    // MARK: - Dashboard Data
    var buckets: [UsageBucket] = []
    var hasAnyData: Bool = false
    var isLoadingData: Bool = false

    // MARK: - Dashboard Controls
    var timeRange: TimeRange = .oneDay
    var filters: FilterState = .init()

    // MARK: - Config
    var isConfigured: Bool = false
    var runtimeAvailable: Bool = true

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
        buckets.reduce(0) { $0 + $1.computedTotal }
    }
    // MARK: - Services (initialized after launch)
    private var syncScheduler: SyncScheduler?
    private var config: VibeUsageConfig?

    // MARK: - Lifecycle

    func initialize() {
        // Load menu bar prefs
        self.showCostInMenuBar = UserDefaults.standard.object(forKey: "showCostInMenuBar") as? Bool ?? true
        self.showTokensInMenuBar = UserDefaults.standard.object(forKey: "showTokensInMenuBar") as? Bool ?? false

        let loadedConfig = ConfigManager.load()
        self.config = loadedConfig
        self.isConfigured = loadedConfig?.apiKey != nil

        let runtime = RuntimeDetector.detect()
        self.runtimeAvailable = runtime != nil

        if isConfigured {
            startScheduler()
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
        isLoadingData = true

        let apiUrl = config.apiUrl ?? AppConfig.defaultApiUrl
        let client = APIClient(baseURL: apiUrl, apiKey: apiKey)

        do {
            let response = try await client.fetchUsage(days: timeRange.days)
            buckets = response.buckets
            hasAnyData = response.hasAnyData
        } catch {
            // Silently fail — dashboard shows stale data or empty state
            print("Failed to fetch usage data: \(error)")
        }

        isLoadingData = false
    }

    // MARK: - Private

    private func startScheduler() {
        syncScheduler = SyncScheduler(interval: 300) { [weak self] in
            await self?.triggerSync()
        }
        syncScheduler?.start()

        // Initial sync + data fetch
        Task {
            await triggerSync()
        }
    }
}
