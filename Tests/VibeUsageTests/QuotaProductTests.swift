import Foundation
import Testing
@testable import VibeUsage

struct QuotaProductTests {
    private final class MemoryZCodeKeyStore: ZCodeAPIKeyStoring {
        var values: [ZCodeQuotaRegion: String] = [:]
        func load(for region: ZCodeQuotaRegion) throws -> String? { values[region] }
        func store(_ value: String?, for region: ZCodeQuotaRegion) throws {
            values[region] = value
        }
    }

    private func defaults() -> (UserDefaults, String) {
        let suite = "QuotaProductTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func products(
        detected: Set<ProviderRateLimit.Provider>
    ) -> [QuotaProduct] {
        QuotaProductRegistry.catalog.map { provider, availability in
            QuotaProduct(
                provider: provider,
                availability: availability,
                isDetected: detected.contains(provider)
            )
        }
    }

    /// A fresh install selects every locally detected product that has a
    /// working adapter — there is no display cap any more, so a machine with
    /// four of them gets four cards. Cursor stays out: it has no stable quota
    /// protocol yet.
    @Test
    func firstLaunchSelectsEveryDetectedReadyProduct() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let selection = QuotaSelectionPreferences.resolve(
            defaults: defaults,
            products: products(detected: [.codex, .claudeCode, .kimiCode, .grok, .cursor])
        )

        #expect(selection == [.codex, .claudeCode, .kimiCode, .grok])
        #expect(defaults.bool(forKey: QuotaSelectionPreferences.initializedKey))
    }

    @Test
    func initializedEmptySelectionStaysEmpty() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set([], forKey: QuotaSelectionPreferences.selectedIDsKey)

        let selection = QuotaSelectionPreferences.resolve(
            defaults: defaults,
            products: products(detected: [.codex, .claudeCode])
        )

        #expect(selection.isEmpty)
    }

    @Test
    func legacySelectionIsMigratedWithoutChangingTheChoice() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "codexRateLimitEnabled")
        defaults.set(true, forKey: "claudeRateLimitEnabled")

        let selection = QuotaSelectionPreferences.resolve(
            defaults: defaults,
            products: products(detected: [.codex, .claudeCode])
        )

        #expect(selection == [.claudeCode])
    }

    @Test
    func storedSelectionIsDeduplicatedAndKeepsEveryProduct() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(
            ["kimi-code", "kimi-code", "codex", "claude-code"],
            forKey: QuotaSelectionPreferences.selectedIDsKey
        )

        let selection = QuotaSelectionPreferences.resolve(
            defaults: defaults,
            products: products(detected: [])
        )

        #expect(selection == [.kimiCode, .codex, .claudeCode])
    }

    /// Selecting another product appends it. Evicting the oldest choice was an
    /// artifact of the two-card layout and would now silently hide a product
    /// the user enabled.
    @Test
    func selectingAnotherProductAppendsInsteadOfEvicting() {
        let selection = QuotaSelectionPreferences.updating(
            [.codex, .claudeCode, .kimiCode],
            provider: .grok,
            selected: true
        )

        #expect(selection == [.codex, .claudeCode, .kimiCode, .grok])
    }

    @Test
    func deselectingRemovesOnlyThatProduct() {
        let selection = QuotaSelectionPreferences.updating(
            [.claudeCode, .grok],
            provider: .claudeCode,
            selected: false
        )

        #expect(selection == [.grok])
    }

    @Test
    func formerCursorGrokSelectionMigratesToCursorWithoutEnablingGrok() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(["cursor-grok"], forKey: QuotaSelectionPreferences.selectedIDsKey)

        let selection = QuotaSelectionPreferences.resolve(
            defaults: defaults,
            products: products(detected: [.cursor, .grok])
        )

        #expect(selection == [.cursor])
        #expect(defaults.stringArray(forKey: QuotaSelectionPreferences.selectedIDsKey) == ["cursor"])
    }

    @Test
    func discoveryUsesOnlyLocalPresenceSignals() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuotaProductTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".codex", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".kimi", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".grok", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".local/share/opencode", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: applications.appendingPathComponent("Cursor.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let discovered = QuotaProductRegistry.discover(
            fileManager: fileManager,
            environment: .init(
                homeDirectory: home,
                applicationDirectories: [applications],
                executableDirectories: [bin]
            )
        )
        let byProvider = Dictionary(uniqueKeysWithValues: discovered.map { ($0.provider, $0) })

        #expect(byProvider[.codex]?.isDetected == true)
        #expect(byProvider[.kimiCode]?.isDetected == true)
        #expect(byProvider[.grok]?.isDetected == true)
        #expect(byProvider[.cursor]?.isDetected == true)
        #expect(byProvider[.opencodeGo]?.isDetected == true)
        #expect(byProvider[.zCode]?.isDetected == false)
        #expect(byProvider[.kimiCode]?.isSelectable == true)
        #expect(byProvider[.grok]?.isSelectable == true)
        #expect(byProvider[.opencodeGo]?.isSelectable == true)
        #expect(byProvider[.cursor]?.isSelectable == false)
    }

    /// OpenCode Go detection is the CLI's *data* home (where `auth.json` holds
    /// the Go key), not the CLI's global install directory — the menu bar app
    /// must not offer a card it could never read.
    @Test
    func openCodeDetectionRequiresTheCLIDataHome() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuotaProductTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".opencodeGo/bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let discovered = QuotaProductRegistry.discover(
            fileManager: fileManager,
            environment: .init(homeDirectory: home, applicationDirectories: [], executableDirectories: [])
        )
        let openCode = try #require(discovered.first(where: { $0.provider == .opencodeGo }))
        #expect(openCode.isDetected == false)
    }

    @Test @MainActor
    func detectedCursorCanBeChosenManuallyButIsNotAutoSelected() async {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: MemoryZCodeKeyStore(),
            quotaProductDiscoverer: { self.products(detected: [.cursor]) }
        )

        appState.initializeQuotaProducts()
        #expect(appState.selectedQuotaProviders.isEmpty)
        #expect(appState.canSelectQuotaProvider(.cursor))

        await appState.setQuotaProductSelected(.cursor, selected: true)
        #expect(appState.selectedQuotaProviders == [.cursor])
        #expect(appState.rateLimits.first(where: { $0.provider == .cursor })?.status == .noData)
    }

    @Test @MainActor
    func manualSelectionRemainsAvailableForEveryCatalogProduct() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(["codex", "claude-code"], forKey: QuotaSelectionPreferences.selectedIDsKey)
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: MemoryZCodeKeyStore(),
            quotaProductDiscoverer: { self.products(detected: []) }
        )

        appState.initializeQuotaProducts()

        #expect(appState.selectedQuotaProviders == [.codex, .claudeCode])
        #expect(appState.canSelectQuotaProvider(.kimiCode))
        #expect(appState.canSelectQuotaProvider(.grok))
        #expect(appState.canSelectQuotaProvider(.zCode))
        #expect(appState.canSelectQuotaProvider(.cursor))
    }

    @Test @MainActor
    func zCodeStatusReflectsExplicitAppOwnedKey() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyStore = MemoryZCodeKeyStore()
        let appState = AppState(quotaDefaults: defaults, zCodeAPIKeyStore: keyStore)
        let product = QuotaProduct(provider: .zCode, availability: .ready, isDetected: true)

        #expect(appState.quotaProductStatusText(product) == "需配置 BigModel API Key")
        try appState.storeZCodeAPIKey("  fixture-key  ")
        #expect(keyStore.values[.bigModel] == "fixture-key")
        #expect(appState.zCodeAPIKeyForQuotaFetch() == "fixture-key")
        #expect(appState.quotaProductStatusText(product) == "已检测 · BigModel（国内） 已配置")

        try appState.storeZCodeAPIKey(nil)
        #expect(keyStore.values[.bigModel] == nil)
        #expect(!appState.zCodeAPIKeyConfigured)
    }

    @Test @MainActor
    func existingZAIKeyKeepsItsRegionWhileBigModelUsesASeparateSecret() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyStore = MemoryZCodeKeyStore()
        keyStore.values[.zAI] = "legacy-zai-key"
        keyStore.values[.bigModel] = "domestic-key"
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: keyStore,
            quotaProductDiscoverer: { self.products(detected: [.zCode]) }
        )

        appState.initializeQuotaProducts()
        #expect(appState.zCodeQuotaRegion == .zAI)
        #expect(appState.zCodeAPIKeyForQuotaFetch() == "legacy-zai-key")

        await appState.setZCodeQuotaRegion(.bigModel)
        #expect(appState.zCodeQuotaRegion == .bigModel)
        #expect(appState.zCodeAPIKeyForQuotaFetch() == "domestic-key")
        #expect(keyStore.values[.zAI] == "legacy-zai-key")
    }
}

// MARK: - Tab strip

extension QuotaProductTests {
    private func catalogProducts() -> [QuotaProduct] {
        QuotaProductRegistry.catalog.map {
            QuotaProduct(provider: $0.0, availability: $0.1, isDetected: true)
        }
    }

    /// The strip shows the whole catalog, so the stored order must cover every
    /// product: unknown ids (a product that left the catalog, or one written by
    /// a newer build) are dropped and new products are appended.
    @Test
    func productOrderCoversTheCatalogAndDropsUnknownIds() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["grok", "ghost-product", "codex"], forKey: QuotaSelectionPreferences.orderKey)

        let order = QuotaSelectionPreferences.resolveOrder(
            defaults: defaults,
            products: catalogProducts()
        )

        #expect(order.prefix(2) == [.grok, .codex])
        #expect(!order.contains(where: { $0.rawValue == "ghost-product" }))
        #expect(Set(order) == Set(QuotaProductRegistry.catalog.map(\.0)))
        // Normalized order is written back, so the ghost id does not linger.
        let stored = defaults.array(forKey: QuotaSelectionPreferences.orderKey) as? [String]
        #expect(stored?.contains("ghost-product") == false)
    }

    @Test
    func selectedTabFallsBackToTheFirstTabWhenItsProductIsGone() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("zcode", forKey: QuotaSelectionPreferences.selectedTabKey)
        #expect(QuotaSelectionPreferences.resolveSelectedTab(defaults: defaults, order: [.zCode, .grok]) == .zCode)

        defaults.set("ghost-product", forKey: QuotaSelectionPreferences.selectedTabKey)
        #expect(QuotaSelectionPreferences.resolveSelectedTab(defaults: defaults, order: [.grok, .codex]) == .grok)
    }

    /// Enabled products come first, disabled ones after, each group in the
    /// user's persisted order — turning a product off moves its tab to the grey
    /// group instead of removing it.
    @Test @MainActor
    func tabStripPutsEnabledProductsFirstInStoredOrder() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(["grok", "codex"], forKey: QuotaSelectionPreferences.selectedIDsKey)
        defaults.set(
            ["opencode-go", "grok", "cursor", "codex", "claude-code"],
            forKey: QuotaSelectionPreferences.orderKey
        )
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: MemoryZCodeKeyStore(),
            quotaProductDiscoverer: { self.catalogProducts() }
        )
        appState.initializeQuotaProducts()

        let order = appState.quotaTabOrder
        #expect(Array(order.prefix(2)) == [.grok, .codex])
        #expect(Set(order.dropFirst(2)) == Set([.opencodeGo, .cursor, .claudeCode, .kimiCode, .zCode]))
        #expect(appState.selectedQuotaTab == .grok)
    }

    /// Dragging reorders within the strip and persists; because enabled products
    /// render as their own group, a drop past the last tab means the end of the
    /// dragged product's group.
    @Test @MainActor
    func draggingATabPersistsItsNewOrder() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(["codex", "claude-code", "grok"], forKey: QuotaSelectionPreferences.selectedIDsKey)
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: MemoryZCodeKeyStore(),
            quotaProductDiscoverer: { self.catalogProducts() }
        )
        appState.initializeQuotaProducts()

        appState.moveQuotaProduct(.grok, before: .codex)
        #expect(Array(appState.quotaTabOrder.prefix(3)) == [.grok, .codex, .claudeCode])

        appState.moveQuotaProduct(.grok, before: nil)
        #expect(Array(appState.quotaTabOrder.prefix(3)) == [.codex, .claudeCode, .grok])

        let stored = defaults.array(forKey: QuotaSelectionPreferences.orderKey) as? [String] ?? []
        #expect(Array(stored.prefix(3)) == ["codex", "claude-code", "grok"])
    }

    /// A disabled product's drop lands in the grey group: the "enabled first"
    /// rule outranks a cross-group drag.
    @Test @MainActor
    func draggingADisabledTabCannotLiftItAboveEnabledProducts() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(["codex"], forKey: QuotaSelectionPreferences.selectedIDsKey)
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: MemoryZCodeKeyStore(),
            quotaProductDiscoverer: { self.catalogProducts() }
        )
        appState.initializeQuotaProducts()

        appState.moveQuotaProduct(.grok, before: .codex)

        #expect(appState.quotaTabOrder.first == .codex)
        #expect(appState.quotaTabOrder.dropFirst().first == .grok)
    }

    @Test @MainActor
    func selectingATabPersistsAndNeverChangesMonitoring() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(["codex"], forKey: QuotaSelectionPreferences.selectedIDsKey)
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: MemoryZCodeKeyStore(),
            quotaProductDiscoverer: { self.catalogProducts() }
        )
        appState.initializeQuotaProducts()

        appState.selectQuotaTab(.opencodeGo)

        #expect(appState.selectedQuotaTab == .opencodeGo)
        #expect(defaults.string(forKey: QuotaSelectionPreferences.selectedTabKey) == "opencode-go")
        // Looking at a product is not opting into it.
        #expect(appState.isQuotaProviderSelected(.opencodeGo) == false)
        #expect(appState.selectedQuotaProviders == [.codex])
    }
}

// MARK: - Cards and warnings

extension QuotaProductTests {
    @MainActor
    private func makeAppState(
        defaults: UserDefaults,
        selected: [String],
        order: [String] = []
    ) -> AppState {
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(selected, forKey: QuotaSelectionPreferences.selectedIDsKey)
        if !order.isEmpty { defaults.set(order, forKey: QuotaSelectionPreferences.orderKey) }
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: MemoryZCodeKeyStore(),
            quotaProductDiscoverer: { self.catalogProducts() }
        )
        appState.initializeQuotaProducts()
        return appState
    }

    /// Only enabled products own a card: turning one off removes its card (its
    /// grey tab leads to Settings instead), and an all-off selection leaves the
    /// section at the icon row with nothing under it.
    @Test @MainActor
    func cardsExistOnlyForEnabledProducts() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = makeAppState(
            defaults: defaults,
            selected: ["grok", "codex"],
            order: ["cursor", "grok", "opencode-go", "codex"]
        )
        #expect(appState.quotaCardProviders == [.grok, .codex])

        let (emptyDefaults, emptySuite) = self.defaults()
        defer { emptyDefaults.removePersistentDomain(forName: emptySuite) }
        let empty = makeAppState(defaults: emptyDefaults, selected: [])
        #expect(empty.quotaCardProviders.isEmpty)
        // The strip still lists the whole catalog, so nothing is unreachable.
        #expect(empty.quotaTabOrder.count == QuotaProductRegistry.catalog.count)
    }

    /// The amber dot means "enabled, but this product is not producing quota":
    /// a settled non-`ok` snapshot. A refresh in flight, a healthy product, a
    /// disabled product and a product with no snapshot yet all stay plain.
    @Test @MainActor
    func tabsWarnOnlyForEnabledProductsWithoutUsableData() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = makeAppState(defaults: defaults, selected: ["codex", "opencode-go"])

        appState.rateLimits = [
            ProviderRateLimit(provider: .codex, status: .ok),
            ProviderRateLimit(provider: .opencodeGo, status: .noData, emptyReason: .notEntitled),
        ]
        #expect(appState.quotaTabShowsWarning(.opencodeGo))
        #expect(appState.quotaTabShowsWarning(.codex) == false)
        // Not enabled: no card, no dot — its tab is grey instead.
        #expect(appState.quotaTabShowsWarning(.grok) == false)

        // A fetch in flight is not a problem — the card shows its spinner.
        appState.isOpenCodeGoRateLimitRefreshing = true
        #expect(appState.quotaTabShowsWarning(.opencodeGo) == false)

        appState.isOpenCodeGoRateLimitRefreshing = false
        appState.rateLimits = []
        #expect(appState.quotaTabShowsWarning(.codex) == false)
    }
}
