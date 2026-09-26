import Foundation

/// Refreshes rate-limit snapshots on demand and pushes results into AppState.
///
/// Both providers follow the same shape: paint an on-disk snapshot instantly,
/// then replace it with a live reading.
///
/// Codex is network-first: `CodexUsageAPI` reads the zero-quota usage endpoint
/// with the CLI's own OAuth token (a plain-file read — no prompts), falling
/// back to the session-JSONL scan when offline or logged out.
///
/// Claude paints from `ClaudeUsageCache` (Claude Code's own `~/.claude.json`
/// cache, else Claude Desktop's usage history) and then runs
/// `ClaudeUsageProbe`, which delegates the actual fetch to a Claude Code binary
/// over the stdio control protocol. That replaced the statusline capture hook,
/// which could never work for Claude Desktop users — Desktop hosts sessions
/// through the SDK and never renders a statusline.
///
/// Nothing is uploaded to the Vibe Usage backend. There is no background
/// timer — refreshes are driven by popover-open (debounced) and user-initiated
/// actions.
@MainActor
final class RateLimitCoordinator {
    private weak var appState: AppState?
    private var lastCodexFetchAt: Date?
    private var lastClaudeFetchAt: Date?
    private var lastOpenCodeGoFetchAt: Date?
    private var isPanelVisible = false
    private var codexRefreshTask: Task<Void, Never>?
    private var codexRefreshID: UUID?
    private var claudeRefreshTask: Task<Void, Never>?
    private var claudeRefreshID: UUID?
    private var openCodeGoRefreshTask: Task<Void, Never>?
    private var openCodeGoRefreshID: UUID?
    private var cliRefreshTask: Task<Void, Never>?
    private var cliRefreshID: UUID?
    private var activeCLIProviders: Set<ProviderRateLimit.Provider> = []
    private var lastCLIFetchAt: [ProviderRateLimit.Provider: Date] = [:]
    private var cliCancellationGeneration: UInt = 0
    private let fetchCodexLive: @MainActor () async throws -> ProviderRateLimit
    private let loadCodexCache: @MainActor () async -> ProviderRateLimit?
    private let readCodexFallback: @MainActor () async -> ProviderRateLimit
    private let fetchClaudeLive: @MainActor () async throws -> ProviderRateLimit
    private let loadClaudeCache: @MainActor () async -> ProviderRateLimit?
    private let fetchOpenCodeGoLive: @MainActor () async throws -> ProviderRateLimit
    private let fetchCLIQuotas: @MainActor (
        [ProviderRateLimit.Provider], String?, ZCodeQuotaRegion
    ) async throws -> [ProviderRateLimit]

    init(
        appState: AppState,
        fetchCodexLive: @escaping @MainActor () async throws -> ProviderRateLimit = {
            try await CodexUsageAPI.fetch()
        },
        loadCodexCache: @escaping @MainActor () async -> ProviderRateLimit? = {
            await RateLimitCoordinator.loadCachedCodexSnapshot()
        },
        readCodexFallback: @escaping @MainActor () async -> ProviderRateLimit = {
            await RateLimitCoordinator.readCodexSessionFiles()
        },
        fetchClaudeLive: @escaping @MainActor () async throws -> ProviderRateLimit = {
            try await ClaudeUsageProbe.fetch()
        },
        loadClaudeCache: @escaping @MainActor () async -> ProviderRateLimit? = {
            await RateLimitCoordinator.loadClaudeDiskSnapshot()
        },
        fetchOpenCodeGoLive: @escaping @MainActor () async throws -> ProviderRateLimit = {
            try await OpenCodeGoUsageAPI.fetch()
        },
        fetchCLIQuotas: @escaping @MainActor (
            [ProviderRateLimit.Provider], String?, ZCodeQuotaRegion
        ) async throws -> [ProviderRateLimit] = { providers, zCodeAPIKey, zCodeRegion in
            try await QuotaCLIBridge.fetch(
                providers: providers,
                zCodeAPIKey: zCodeAPIKey,
                zCodeRegion: zCodeRegion
            )
        }
    ) {
        self.appState = appState
        self.fetchCodexLive = fetchCodexLive
        self.loadCodexCache = loadCodexCache
        self.readCodexFallback = readCodexFallback
        self.fetchClaudeLive = fetchClaudeLive
        self.loadClaudeCache = loadClaudeCache
        self.fetchOpenCodeGoLive = fetchOpenCodeGoLive
        self.fetchCLIQuotas = fetchCLIQuotas
    }

    /// Refresh Codex unconditionally: live endpoint first, JSONL fallback.
    /// Used by the manual "更新数据" path; popover-open should prefer the
    /// debounced `refreshCodexIfNeeded` to avoid repeat work on rapid open/close.
    func refreshCodex() async {
        guard let appState, appState.codexRateLimitEnabled else { return }
        if let task = codexRefreshTask {
            await task.value
            return
        }

        let refreshID = UUID()
        appState.isCodexRateLimitRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCodexRefresh()
        }
        codexRefreshID = refreshID
        codexRefreshTask = task
        await task.value

        // A cancelled task may finish after a new refresh has already started.
        // Only the task that still owns the slot may clear it or the spinner.
        if codexRefreshID == refreshID {
            codexRefreshTask = nil
            codexRefreshID = nil
            appState.isCodexRateLimitRefreshing = false
        }
    }

    private func performCodexRefresh() async {
        guard let appState, appState.codexRateLimitEnabled else { return }
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        TestDiagnosticLog.recordQuotaRefreshStarted([.codex])
        #endif

        // Instant paint: if nothing usable is on screen yet, surface the last
        // *live* snapshot (single small file, negligible read) so the card
        // doesn't sit empty for the ~1s the network round-trip takes. That
        // cache beats the session JSONL as a paint source on both axes: it is
        // at most as old as the previous successful refresh (the JSONL only
        // updates while Codex is running) and it never walks the sessions
        // tree (which can be hundreds of MB). Expired windows are filtered on
        // load; the live result replaces the paint right after.
        if currentSnapshot(.codex)?.status != .ok,
           let cached = await loadCodexCache(),
           !Task.isCancelled,
           appState.codexRateLimitEnabled,
           currentSnapshot(.codex)?.status != .ok {
            upsert(cached)
        }

        do {
            let live = try await fetchCodexLive()
            guard !Task.isCancelled, appState.codexRateLimitEnabled else { return }
            upsert(live)
        } catch is CancellationError {
            #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
            TestDiagnosticLog.recordQuotaCancelled([.codex])
            #endif
            return
        } catch {
            #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
            TestDiagnosticLog.recordQuotaFailure([.codex], error: error)
            #endif
            // Offline / endpoint drift → degrade to exactly the pre-network
            // behavior: whatever the session JSONL has. If the JSONL has
            // nothing but a previous live snapshot is still on screen, keep
            // it — its 「数据截至」 note communicates the age honestly, which
            // beats replacing a real reading over a transient network blip. On
            // a cold read, distinguish "Codex is not installed/logged in" from
            // an actual request failure: the latter must stay visible with a
            // retry affordance instead of being reported as 「暂无数据」.
            let failure = Self.classify(error)
            if failure == .unauthorized {
                debugLog("[rate-limit] codex live fetch unauthorized — user logged out of Codex CLI")
            } else {
                debugLog("[rate-limit] codex live fetch failed (\(error)) — falling back to session JSONL")
            }
            let fallback = await readCodexFallback()
            guard !Task.isCancelled, appState.codexRateLimitEnabled else { return }
            if fallback.status == .ok {
                upsertIfNewer(fallback)
            } else if currentSnapshot(.codex)?.status != .ok {
                let status: ProviderRateLimit.Status
                switch failure {
                case .absent, .notApplicable:
                    status = .noData
                case .unauthorized:
                    status = .unauthorized
                case .transient:
                    status = .retryableError
                }
                upsert(ProviderRateLimit(provider: .codex, status: status, fetchedAt: Date()))
            }
        }
        guard !Task.isCancelled else { return }
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        if let snapshot = currentSnapshot(.codex) {
            TestDiagnosticLog.recordQuotaResult(snapshot)
        }
        #endif
        lastCodexFetchAt = Date()
    }

    /// Refresh Codex only if we haven't refreshed within `maxAge` seconds.
    /// Mirrors `fetchUsageDataIfNeeded` so popover-open doesn't re-hit the
    /// endpoint when the user toggles the popover repeatedly.
    func refreshCodexIfNeeded(maxAge: TimeInterval = 60) async {
        if let last = lastCodexFetchAt, Date().timeIntervalSince(last) < maxAge {
            return
        }
        await refreshCodex()
    }

    /// Refresh Claude: paint the on-disk cache, then run the probe.
    /// Only runs while Claude monitoring is enabled.
    func refreshClaude() async {
        guard let appState, appState.claudeRateLimitEnabled else { return }
        if let task = claudeRefreshTask {
            await task.value
            return
        }

        let refreshID = UUID()
        appState.isClaudeRateLimitRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performClaudeRefresh()
        }
        claudeRefreshID = refreshID
        claudeRefreshTask = task
        await task.value

        if claudeRefreshID == refreshID {
            claudeRefreshTask = nil
            claudeRefreshID = nil
            appState.isClaudeRateLimitRefreshing = false
        }
    }

    private func performClaudeRefresh() async {
        guard let appState, appState.claudeRateLimitEnabled else { return }
        debugLog("[rate-limit] refreshClaude() entered")
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        TestDiagnosticLog.recordQuotaRefreshStarted([.claudeCode])
        #endif

        // Instant paint from disk, for the same reason Codex does it: the live
        // reading costs a ~2.5s subprocess round trip, and an empty card for
        // that long reads as "broken". Skipped once real data is on screen.
        if currentSnapshot(.claudeCode)?.status != .ok,
           let cached = await loadClaudeCache(),
           !Task.isCancelled,
           appState.claudeRateLimitEnabled,
           currentSnapshot(.claudeCode)?.status != .ok {
            upsert(cached)
        }

        do {
            let live = try await fetchClaudeLive()
            guard !Task.isCancelled, appState.claudeRateLimitEnabled else { return }
            upsert(live)
        } catch is CancellationError {
            #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
            TestDiagnosticLog.recordQuotaCancelled([.claudeCode])
            #endif
            return
        } catch {
            #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
            TestDiagnosticLog.recordQuotaFailure([.claudeCode], error: error)
            #endif
            let failure = Self.classify(error)
            guard !Task.isCancelled, appState.claudeRateLimitEnabled else { return }
            if failure == .notApplicable {
                // API key / Bedrock / Vertex session: this account has no plan
                // quota at all, so there is nothing to show and nothing to retry.
                debugLog("[rate-limit] claude plan limits not applicable for this account")
                upsert(ProviderRateLimit(provider: .claudeCode, status: .noData, fetchedAt: Date()))
            } else {
                // No binary, offline, or the binary's own usage fetch failed.
                // Keep whatever cache painted; with no cache, absence stays
                // quiet while a concrete failure remains retryable.
                debugLog("[rate-limit] claude probe failed (\(error)) — keeping cached snapshot")
                if currentSnapshot(.claudeCode)?.status != .ok {
                    let status: ProviderRateLimit.Status = failure == .absent
                        ? .noData
                        : .retryableError
                    upsert(ProviderRateLimit(provider: .claudeCode, status: status, fetchedAt: Date()))
                }
            }
        }
        guard !Task.isCancelled else { return }
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        if let snapshot = currentSnapshot(.claudeCode) {
            TestDiagnosticLog.recordQuotaResult(snapshot)
        }
        #endif
        lastClaudeFetchAt = Date()
    }

    /// Refresh Claude only if the last read was over `maxAge` seconds ago.
    /// Mirrors `refreshCodexIfNeeded` for the debounced popover-open path.
    func refreshClaudeIfNeeded(maxAge: TimeInterval = 60) async {
        if let last = lastClaudeFetchAt, Date().timeIntervalSince(last) < maxAge {
            return
        }
        await refreshClaude()
    }

    /// Refresh OpenCode Go: one account-wide HTTPS call, no local fallback (the
    /// subscription windows exist only server-side). Gated on the product
    /// selection so an unselected provider never reaches the network.
    func refreshOpenCodeGo() async {
        guard let appState, appState.isQuotaProviderSelected(.opencode) else { return }
        if let task = openCodeGoRefreshTask {
            await task.value
            return
        }

        let refreshID = UUID()
        appState.isOpenCodeGoRateLimitRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performOpenCodeGoRefresh()
        }
        openCodeGoRefreshID = refreshID
        openCodeGoRefreshTask = task
        await task.value

        if openCodeGoRefreshID == refreshID {
            openCodeGoRefreshTask = nil
            openCodeGoRefreshID = nil
            appState.isOpenCodeGoRateLimitRefreshing = false
        }
    }

    private func performOpenCodeGoRefresh() async {
        guard let appState, appState.isQuotaProviderSelected(.opencode) else { return }
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        TestDiagnosticLog.recordQuotaRefreshStarted([.opencode])
        #endif

        do {
            let live = try await fetchOpenCodeGoLive()
            guard !Task.isCancelled, appState.isQuotaProviderSelected(.opencode) else { return }
            upsert(live)
        } catch is CancellationError {
            #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
            TestDiagnosticLog.recordQuotaCancelled([.opencode])
            #endif
            return
        } catch {
            #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
            TestDiagnosticLog.recordQuotaFailure([.opencode], error: error)
            #endif
            let failure = Self.classify(error)
            guard !Task.isCancelled, appState.isQuotaProviderSelected(.opencode) else { return }
            // A live reading already on screen survives a transient blip: its
            // 「数据截至」 note states the age honestly, which beats replacing a
            // real reading with an error. Only a cold card commits a status.
            if currentSnapshot(.opencode)?.status != .ok {
                switch failure {
                case .notApplicable:
                    // 403 EntitlementError: the account has no Go plan. That is
                    // the endpoint's answer, not a failed read, so the card says
                    // so once instead of offering a retry that cannot succeed.
                    debugLog("[rate-limit] opencode go not entitled for this account")
                    upsert(ProviderRateLimit(provider: .opencode, status: .noData,
                        fetchedAt: Date(), emptyReason: .notEntitled))
                case .absent:
                    upsert(ProviderRateLimit(provider: .opencode, status: .noData,
                        fetchedAt: Date()))
                case .unauthorized:
                    upsert(ProviderRateLimit(provider: .opencode, status: .unauthorized,
                        fetchedAt: Date()))
                case .transient:
                    debugLog("[rate-limit] opencode go fetch failed (\(error))")
                    upsert(ProviderRateLimit(provider: .opencode, status: .retryableError,
                        fetchedAt: Date()))
                }
            }
        }
        guard !Task.isCancelled else { return }
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        if let snapshot = currentSnapshot(.opencode) {
            TestDiagnosticLog.recordQuotaResult(snapshot)
        }
        #endif
        lastOpenCodeGoFetchAt = Date()
    }

    /// Refresh OpenCode Go only if the last read was over `maxAge` seconds ago.
    func refreshOpenCodeGoIfNeeded(maxAge: TimeInterval = 60) async {
        if let last = lastOpenCodeGoFetchAt, Date().timeIntervalSince(last) < maxAge {
            return
        }
        await refreshOpenCodeGo()
    }

    /// Fetches one versioned CLI envelope for the requested CLI-backed set.
    /// The CLI isolates provider failures, while this boundary also guards the
    /// current selection before starting and again before publishing results.
    func refreshCLIProviders(_ providers: [ProviderRateLimit.Provider]) async {
        guard let appState else { return }
        let requested = providers.reduce(into: [ProviderRateLimit.Provider]()) { result, provider in
            guard provider.usesQuotaCLI,
                  appState.isQuotaProviderSelected(provider),
                  !result.contains(provider)
            else { return }
            result.append(provider)
        }
        guard !requested.isEmpty else { return }

        if let task = cliRefreshTask {
            let alreadyCovered = activeCLIProviders
            let cancellationGeneration = cliCancellationGeneration
            await task.value
            guard !Task.isCancelled, cancellationGeneration == cliCancellationGeneration else { return }
            let remaining = requested.filter {
                !alreadyCovered.contains($0) && appState.isQuotaProviderSelected($0)
            }
            if !remaining.isEmpty { await refreshCLIProviders(remaining) }
            return
        }

        let refreshID = UUID()
        let requestedSet = Set(requested)
        activeCLIProviders = requestedSet
        appState.cliQuotaRefreshingProviders.formUnion(requestedSet)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCLIRefresh(requested)
            if self.cliRefreshID == refreshID {
                self.cliRefreshTask = nil
                self.cliRefreshID = nil
                self.activeCLIProviders = []
                self.appState?.cliQuotaRefreshingProviders.subtract(requestedSet)
            }
        }
        cliRefreshID = refreshID
        cliRefreshTask = task
        await task.value
    }

    private func performCLIRefresh(_ providers: [ProviderRateLimit.Provider]) async {
        guard let appState else { return }
        // Keep the exact regional credential context that started this request.
        // A Key/region change invalidates only ZCode; unrelated products from a
        // shared CLI response remain usable.
        let requestsZCode = providers.contains(.zCode)
        let requestedZCodeKey = requestsZCode
            ? appState.zCodeAPIKeyForQuotaFetch()
            : nil
        let requestedZCodeRegion = appState.zCodeQuotaRegion
        #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
        TestDiagnosticLog.recordQuotaRefreshStarted(providers)
        #endif
        do {
            let snapshots = try await fetchCLIQuotas(
                providers,
                requestedZCodeKey,
                requestedZCodeRegion
            )
            guard !Task.isCancelled else { return }
            let zCodeContextIsCurrent = !requestsZCode || (
                requestedZCodeKey == appState.zCodeAPIKeyForQuotaFetch()
                    && requestedZCodeRegion == appState.zCodeQuotaRegion
            )
            for provider in providers where appState.isQuotaProviderSelected(provider)
                && (provider != .zCode || zCodeContextIsCurrent) {
                if let snapshot = snapshots.first(where: { $0.provider == provider }) {
                    if snapshot.status == .ok {
                        _ = upsertIfNewer(snapshot)
                    } else if snapshot.status != .retryableError
                                || currentSnapshot(provider)?.status != .ok {
                        upsert(snapshot)
                    }
                    #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
                    TestDiagnosticLog.recordQuotaResult(snapshot)
                    #endif
                } else {
                    #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
                    TestDiagnosticLog.recordMissingQuotaResult(provider)
                    #endif
                    if currentSnapshot(provider)?.status != .ok {
                        upsert(ProviderRateLimit(
                            provider: provider,
                            status: .retryableError,
                            fetchedAt: Date()
                        ))
                    }
                }
                lastCLIFetchAt[provider] = Date()
            }
        } catch is CancellationError {
            #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
            TestDiagnosticLog.recordQuotaCancelled(providers)
            #endif
            return
        } catch {
            debugLog("[rate-limit] quota CLI failed: \(error)")
            #if DEBUG || VIBE_USAGE_EXTERNAL_TEST
            TestDiagnosticLog.recordQuotaFailure(providers, error: error)
            #endif
            guard !Task.isCancelled else { return }
            let zCodeContextIsCurrent = !requestsZCode || (
                requestedZCodeKey == appState.zCodeAPIKeyForQuotaFetch()
                    && requestedZCodeRegion == appState.zCodeQuotaRegion
            )
            for provider in providers where appState.isQuotaProviderSelected(provider)
                && (provider != .zCode || zCodeContextIsCurrent) {
                if currentSnapshot(provider)?.status != .ok {
                    upsert(ProviderRateLimit(
                        provider: provider,
                        status: .retryableError,
                        fetchedAt: Date()
                    ))
                }
                lastCLIFetchAt[provider] = Date()
            }
        }
    }

    func refreshCLIProvidersIfNeeded(
        _ providers: [ProviderRateLimit.Provider],
        maxAge: TimeInterval = 60
    ) async {
        let stale = providers.filter { provider in
            guard let last = lastCLIFetchAt[provider] else { return true }
            return Date().timeIntervalSince(last) >= maxAge
        }
        await refreshCLIProviders(stale)
    }

    /// Refresh everything currently visible, in parallel — the Codex and
    /// OpenCode Go legs each include a network round-trip, so serializing would
    /// add up the waits.
    func refreshAll() async {
        async let codex: Void = refreshCodex()
        async let claude: Void = refreshClaude()
        async let openCodeGo: Void = refreshOpenCodeGo()
        async let cli: Void = refreshCLIProviders(
            appState?.selectedQuotaProviders.filter(\.usesQuotaCLI) ?? []
        )
        _ = await (codex, claude, openCodeGo, cli)
    }

    /// Popover-open refresh for the selected products only. Keeping the fan-out
    /// here ensures an unselected provider never performs network or subprocess
    /// work even as the product catalog grows.
    func refreshSelectedIfNeeded() async {
        async let codex: Void = refreshCodexIfNeeded()
        async let claude: Void = refreshClaudeIfNeeded()
        async let openCodeGo: Void = refreshOpenCodeGoIfNeeded()
        async let cli: Void = refreshCLIProvidersIfNeeded(
            appState?.selectedQuotaProviders.filter(\.usesQuotaCLI) ?? []
        )
        _ = await (codex, claude, openCodeGo, cli)
    }

    /// Ensure every enabled provider has a placeholder entry so the card row
    /// renders its loading state on a cold open instead of appearing empty.
    func seedPlaceholders() {
        for provider in appState?.selectedQuotaProviders ?? [] {
            seedPlaceholder(for: provider)
        }
    }

    func seedPlaceholder(for provider: ProviderRateLimit.Provider) {
        guard appState?.isQuotaProviderSelected(provider) == true,
              appState?.rateLimits.contains(where: { $0.provider == provider }) != true
        else { return }
        upsert(ProviderRateLimit(provider: provider, status: .noData, fetchedAt: nil))
    }

    // MARK: - Panel lifecycle

    /// Off-screen refreshes have no one to display them, and both providers now
    /// cost a real round trip (Codex over HTTP, Claude over a subprocess), so
    /// closing the panel cancels whatever is in flight.
    ///
    /// There is no live file watcher any more: the statusline capture that used
    /// to justify one is gone, and both providers refresh on open instead.
    func panelVisibilityChanged(visible: Bool) {
        isPanelVisible = visible
        if !visible {
            cancelCodexRefresh()
            cancelClaudeRefresh()
            cancelCLIRefresh()
        }
    }

    /// Stop an in-flight Claude probe the moment monitoring is switched off, so
    /// a subprocess started for a now-hidden card doesn't outlive it.
    func claudeMonitoringDidChange() {
        if appState?.claudeRateLimitEnabled != true {
            cancelClaudeRefresh()
        }
    }

    // MARK: - Helpers

    /// Stop network work when the UI that requested it disappears. The
    /// generation id prevents a late completion from clearing a newer task.
    func cancelCodexRefresh() {
        codexRefreshTask?.cancel()
        codexRefreshTask = nil
        codexRefreshID = nil
        appState?.isCodexRateLimitRefreshing = false
    }

    func cancelClaudeRefresh() {
        claudeRefreshTask?.cancel()
        claudeRefreshTask = nil
        claudeRefreshID = nil
        appState?.isClaudeRateLimitRefreshing = false
    }

    func cancelOpenCodeGoRefresh() {
        openCodeGoRefreshTask?.cancel()
        openCodeGoRefreshTask = nil
        openCodeGoRefreshID = nil
        appState?.isOpenCodeGoRateLimitRefreshing = false
    }

    func cancelRefresh(for provider: ProviderRateLimit.Provider) {
        switch provider {
        case .codex:
            cancelCodexRefresh()
        case .claudeCode:
            cancelClaudeRefresh()
        case .kimiCode, .zCode, .grok:
            cancelCLIRefresh()
        case .opencode:
            cancelOpenCodeGoRefresh()
        case .cursor: break
        }
    }

    /// ZCode's Key and region are part of its cache/request identity. Drop its
    /// debounce timestamp and cancel a shared CLI request only when that
    /// request actually includes ZCode.
    func zCodeCredentialContextDidChange() {
        lastCLIFetchAt[.zCode] = nil
        if activeCLIProviders.contains(.zCode) {
            cancelCLIRefresh()
        }
    }

    func cancelCLIRefresh() {
        cliCancellationGeneration &+= 1
        cliRefreshTask?.cancel()
        cliRefreshTask = nil
        cliRefreshID = nil
        activeCLIProviders = []
        appState?.cliQuotaRefreshingProviders = []
    }

    private nonisolated static func readCodexSessionFiles() async -> ProviderRateLimit {
        let task = Task.detached(priority: .userInitiated) {
            CodexRateLimitReader.read()
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func loadCachedCodexSnapshot() async -> ProviderRateLimit? {
        let task = Task.detached(priority: .userInitiated) {
            CodexUsageAPI.cachedSnapshot()
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func loadClaudeDiskSnapshot() async -> ProviderRateLimit? {
        let task = Task.detached(priority: .userInitiated) {
            ClaudeUsageCache.bestSnapshot()
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func currentSnapshot(_ provider: ProviderRateLimit.Provider) -> ProviderRateLimit? {
        appState?.rateLimits.first { $0.provider == provider }
    }

    /// Provider adapters expose a shared semantic contract. Unknown injected
    /// errors are conservative/transient so tests and future adapters never
    /// make a concrete read failure disappear as mere absence.
    private nonisolated static func classify(_ error: Error) -> RateLimitFetchFailure {
        (error as? any RateLimitFetchError)?.rateLimitFailure ?? .transient
    }

    /// Fallback data may replace the current card only when it was produced
    /// later. This prevents a network failure from making utilization visibly
    /// jump backwards from a recent live cache to an older session event.
    @discardableResult
    private func upsertIfNewer(_ candidate: ProviderRateLimit) -> Bool {
        guard Self.isNewerSnapshot(candidate, than: currentSnapshot(candidate.provider)) else {
            return false
        }
        upsert(candidate)
        return true
    }

    nonisolated static func isNewerSnapshot(
        _ candidate: ProviderRateLimit,
        than current: ProviderRateLimit?
    ) -> Bool {
        guard candidate.status == .ok else { return false }
        guard let current, current.status == .ok else { return true }

        let candidateDate = candidate.dataAsOf ?? candidate.fetchedAt
        let currentDate = current.dataAsOf ?? current.fetchedAt
        switch (candidateDate, currentDate) {
        case let (candidateDate?, currentDate?): return candidateDate > currentDate
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return false
        }
    }

    private func upsert(_ snapshot: ProviderRateLimit) {
        guard let appState else { return }
        var current = appState.rateLimits
        if let i = current.firstIndex(where: { $0.provider == snapshot.provider }) {
            current[i] = snapshot
        } else {
            current.append(snapshot)
        }
        appState.rateLimits = current
    }
}
