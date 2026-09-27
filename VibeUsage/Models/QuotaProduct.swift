import Foundation

enum QuotaProductAvailability: Equatable {
    /// The Mac app has a read-only provider adapter and may fetch this product
    /// when (and only when) the user selects it.
    case ready
    /// Detection is available, but the quota protocol is not yet stable enough
    /// to present as a working integration.
    case pendingProtocol
}

struct QuotaProduct: Equatable, Identifiable {
    var id: String { provider.rawValue }
    var provider: ProviderRateLimit.Provider
    var availability: QuotaProductAvailability
    var isDetected: Bool

    var displayName: String { provider.displayName }
    var isSelectable: Bool { availability == .ready && isDetected }

    var statusText: String {
        switch (availability, isDetected) {
        case (.ready, true): return "已检测"
        case (.ready, false): return "未检测到"
        case (.pendingProtocol, true): return "已检测 · 待接入"
        case (.pendingProtocol, false): return "待接入"
        }
    }
}

/// Local-only product discovery. It checks conventional app/config/executable
/// locations and never opens credentials, launches another product, or reaches
/// the network. Detection means "this product is installed or has local data",
/// not "the account definitely has a paid subscription".
enum QuotaProductRegistry {
    struct DiscoveryEnvironment {
        var homeDirectory: URL
        var applicationDirectories: [URL]
        var executableDirectories: [URL]

        static func live(
            fileManager: FileManager = .default,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> DiscoveryEnvironment {
            let home = fileManager.homeDirectoryForCurrentUser
            let applications = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                home.appendingPathComponent("Applications", isDirectory: true),
            ]
            let pathDirectories = (environment["PATH"] ?? "")
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0), isDirectory: true) }
            let userExecutableDirectories = [
                home.appendingPathComponent(".local/bin", isDirectory: true),
                home.appendingPathComponent(".claude/local", isDirectory: true),
            ]
            return DiscoveryEnvironment(
                homeDirectory: home,
                applicationDirectories: applications,
                executableDirectories: uniqueURLs(userExecutableDirectories + pathDirectories)
            )
        }
    }

    static let catalog: [(ProviderRateLimit.Provider, QuotaProductAvailability)] = [
        (.codex, .ready),
        (.claudeCode, .ready),
        (.kimiCode, .ready),
        (.zCode, .ready),
        (.grok, .ready),
        (.cursor, .pendingProtocol),
        (.opencodeGo, .ready),
    ]

    static func discover(
        fileManager: FileManager = .default,
        environment: DiscoveryEnvironment = .live()
    ) -> [QuotaProduct] {
        catalog.map { provider, availability in
            QuotaProduct(
                provider: provider,
                availability: availability,
                isDetected: isDetected(provider, fileManager: fileManager, environment: environment)
            )
        }
    }

    private static func isDetected(
        _ provider: ProviderRateLimit.Provider,
        fileManager: FileManager,
        environment: DiscoveryEnvironment
    ) -> Bool {
        let home = environment.homeDirectory
        let relativePaths: [String]
        let appNames: [String]
        let executableNames: [String]

        switch provider {
        case .codex:
            relativePaths = [".codex"]
            appNames = ["Codex.app"]
            executableNames = ["codex"]
        case .claudeCode:
            relativePaths = [
                ".claude",
                ".claude.json",
                "Library/Application Support/Claude/claude-code",
            ]
            appNames = ["Claude.app"]
            executableNames = ["claude"]
        case .kimiCode:
            // Deliberately avoid treating the general Kimi chat app as Kimi
            // Code. Only its coding CLI/config locations count.
            relativePaths = [".kimi", ".kimi-code", ".config/kimi"]
            appNames = []
            executableNames = ["kimi"]
        case .zCode:
            relativePaths = [".zcode", ".config/zcode"]
            appNames = ["ZCode.app"]
            executableNames = ["zcode"]
        case .grok:
            relativePaths = [".grok"]
            appNames = []
            executableNames = ["grok"]
        case .cursor:
            relativePaths = [".cursor"]
            appNames = ["Cursor.app"]
            executableNames = ["cursor"]
        case .opencodeGo:
            // The CLI's own data home; `auth.json` inside it holds the Go key.
            // Detection stays a plain path check — entitlement is only known
            // after the (account-wide) usage call, which discovery must not make.
            relativePaths = [".local/share/opencode"]
            appNames = []
            executableNames = ["opencode"]
        }

        if relativePaths.contains(where: {
            fileManager.fileExists(atPath: home.appendingPathComponent($0).path)
        }) {
            return true
        }
        if appNames.contains(where: { appName in
            environment.applicationDirectories.contains(where: { directory in
                fileManager.fileExists(atPath: directory.appendingPathComponent(appName).path)
            })
        }) {
            return true
        }
        return executableNames.contains(where: { executableName in
            environment.executableDirectories.contains(where: { directory in
                fileManager.isExecutableFile(
                    atPath: directory.appendingPathComponent(executableName).path
                )
            })
        })
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

/// Persistence and one-time migration for the product selector. Keeping this
/// policy independent of AppState makes the "never repopulate an intentionally
/// empty selection" invariant directly testable.
enum QuotaSelectionPreferences {
    static let initializedKey = "quotaSelectionInitialized"
    static let selectedIDsKey = "selectedQuotaProductIds"
    /// Display order of every catalog product, enabled or not (tab strip).
    static let orderKey = "quotaProductOrder"
    /// The tab the user last looked at.
    static let selectedTabKey = "quotaSelectedTabId"

    /// Stored order for the whole catalog: unknown ids (a product removed from
    /// the catalog, or written by a newer build) are dropped, and products the
    /// stored order does not know about are appended in catalog order.
    static func resolveOrder(
        defaults: UserDefaults,
        products: [QuotaProduct]
    ) -> [ProviderRateLimit.Provider] {
        let catalog = products.map(\.provider)
        var order = storedOrder(defaults: defaults).filter { catalog.contains($0) }
        for provider in catalog where !order.contains(provider) { order.append(provider) }
        persistOrder(order, defaults: defaults)
        return order
    }

    static func persistOrder(
        _ order: [ProviderRateLimit.Provider],
        defaults: UserDefaults
    ) {
        defaults.set(normalized(order).map(\.rawValue), forKey: orderKey)
    }

    /// The stored tab when it is still in the strip; otherwise the first tab.
    static func resolveSelectedTab(
        defaults: UserDefaults,
        order: [ProviderRateLimit.Provider]
    ) -> ProviderRateLimit.Provider {
        let stored = (defaults.string(forKey: selectedTabKey))
            .flatMap { ProviderRateLimit.Provider(rawValue: $0) }
        if let stored, order.contains(stored) { return stored }
        return order.first ?? .codex
    }

    static func persistSelectedTab(
        _ provider: ProviderRateLimit.Provider,
        defaults: UserDefaults
    ) {
        defaults.set(provider.rawValue, forKey: selectedTabKey)
    }

    private static func storedOrder(
        defaults: UserDefaults
    ) -> [ProviderRateLimit.Provider] {
        (defaults.array(forKey: orderKey) as? [String] ?? [])
            .compactMap { ProviderRateLimit.Provider(rawValue: $0) }
    }

    static func resolve(
        defaults: UserDefaults,
        products: [QuotaProduct]
    ) -> [ProviderRateLimit.Provider] {
        if defaults.bool(forKey: initializedKey) {
            let selection = normalized(storedSelection(defaults: defaults))
            // Rewrite normalized ids so one-time aliases such as the former
            // `cursor-grok` value do not linger indefinitely on disk.
            persist(selection, defaults: defaults)
            return selection
        }

        let hasLegacySelection = defaults.object(forKey: "codexRateLimitEnabled") != nil
            || defaults.object(forKey: "claudeRateLimitEnabled") != nil
            || defaults.object(forKey: "rateLimitMonitoringEnabled") != nil

        let selection: [ProviderRateLimit.Provider]
        if hasLegacySelection {
            let legacyCodex = defaults.object(forKey: "codexRateLimitEnabled") as? Bool
                ?? defaults.object(forKey: "rateLimitMonitoringEnabled") as? Bool
                ?? true
            let legacyClaude = defaults.object(forKey: "claudeRateLimitEnabled") as? Bool ?? true
            selection = [
                legacyCodex ? .codex : nil,
                legacyClaude ? .claudeCode : nil,
            ].compactMap { $0 }
        } else {
            selection = products
                .filter(\.isSelectable)
                .map(\.provider)
        }

        let resolved = normalized(selection)
        persist(resolved, defaults: defaults)
        defaults.set(true, forKey: initializedKey)
        return resolved
    }

    static func persist(
        _ selection: [ProviderRateLimit.Provider],
        defaults: UserDefaults
    ) {
        let normalizedSelection = normalized(selection)
        defaults.set(normalizedSelection.map(\.rawValue), forKey: selectedIDsKey)
        // Keep downgrade behavior unsurprising for the two legacy providers.
        defaults.set(normalizedSelection.contains(.codex), forKey: "codexRateLimitEnabled")
        defaults.set(normalizedSelection.contains(.claudeCode), forKey: "claudeRateLimitEnabled")
    }

    /// Apply one explicit user choice to the display list. Detection is only a
    /// first-launch recommendation: the manual selector must remain usable when
    /// discovery is incomplete. Every selection is kept — the panel scrolls, so
    /// there is no reason to evict an earlier choice to make room.
    static func updating(
        _ selection: [ProviderRateLimit.Provider],
        provider: ProviderRateLimit.Provider,
        selected: Bool
    ) -> [ProviderRateLimit.Provider] {
        var next = normalized(selection).filter { $0 != provider }
        if selected {
            next.append(provider)
        }
        return normalized(next)
    }

    static func normalized(
        _ selection: [ProviderRateLimit.Provider]
    ) -> [ProviderRateLimit.Provider] {
        var seen: Set<ProviderRateLimit.Provider> = []
        return selection.filter { seen.insert($0).inserted }
    }

    private static func storedSelection(
        defaults: UserDefaults
    ) -> [ProviderRateLimit.Provider] {
        (defaults.array(forKey: selectedIDsKey) as? [String] ?? [])
            .compactMap { storedID in
                // The pre-split product represented Cursor presence but had no
                // Grok adapter. Preserve that user choice as Cursor rather than
                // silently opting the user into a newly fetchable product.
                if storedID == "cursor-grok" { return .cursor }
                return ProviderRateLimit.Provider(rawValue: storedID)
            }
    }
}
