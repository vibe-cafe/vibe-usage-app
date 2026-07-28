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
    private var isPanelVisible = false
    private var codexRefreshTask: Task<Void, Never>?
    private var codexRefreshID: UUID?
    private var claudeRefreshTask: Task<Void, Never>?
    private var claudeRefreshID: UUID?
    private let fetchCodexLive: @MainActor () async throws -> ProviderRateLimit
    private let loadCodexCache: @MainActor () async -> ProviderRateLimit?
    private let readCodexFallback: @MainActor () async -> ProviderRateLimit
    private let fetchClaudeLive: @MainActor () async throws -> ProviderRateLimit
    private let loadClaudeCache: @MainActor () async -> ProviderRateLimit?

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
        }
    ) {
        self.appState = appState
        self.fetchCodexLive = fetchCodexLive
        self.loadCodexCache = loadCodexCache
        self.readCodexFallback = readCodexFallback
        self.fetchClaudeLive = fetchClaudeLive
        self.loadClaudeCache = loadClaudeCache
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
            return
        } catch CodexUsageAPI.FetchError.unauthorized {
            // Token rejected even after re-reading auth.json — the user really
            // is logged out of Codex. Stale JSONL data (if any) still renders,
            // with its 「数据截至」 note; otherwise surface the re-login state.
            debugLog("[rate-limit] codex live fetch unauthorized — user logged out of Codex CLI")
            let fallback = await readCodexFallback()
            guard !Task.isCancelled, appState.codexRateLimitEnabled else { return }
            if fallback.status == .ok {
                upsertIfNewer(fallback)
            } else if currentSnapshot(.codex)?.status != .ok {
                upsert(ProviderRateLimit(provider: .codex, status: .unauthorized, fetchedAt: Date()))
            }
        } catch {
            // Offline / endpoint drift → degrade to exactly the pre-network
            // behavior: whatever the session JSONL has. If the JSONL has
            // nothing but a previous live snapshot is still on screen, keep
            // it — its 「数据截至」 note communicates the age honestly, which
            // beats collapsing the card over a transient network blip.
            debugLog("[rate-limit] codex live fetch failed (\(error)) — falling back to session JSONL")
            let fallback = await readCodexFallback()
            guard !Task.isCancelled, appState.codexRateLimitEnabled else { return }
            if fallback.status == .ok {
                upsertIfNewer(fallback)
            } else if currentSnapshot(.codex)?.status != .ok {
                upsert(fallback)
            }
        }
        guard !Task.isCancelled else { return }
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
            return
        } catch ClaudeUsageProbe.ProbeError.limitsNotApplicable {
            // API key / Bedrock / Vertex session: this account has no plan
            // quota at all, so there is nothing to show and nothing to retry.
            // Collapse the card rather than implying a transient failure.
            guard !Task.isCancelled, appState.claudeRateLimitEnabled else { return }
            debugLog("[rate-limit] claude plan limits not applicable for this account")
            upsert(ProviderRateLimit(provider: .claudeCode, status: .noData, fetchedAt: Date()))
        } catch {
            // No binary, offline, or the binary's own usage fetch failed. Keep
            // whatever the cache painted — its 「数据截至」 note states the age
            // honestly, which beats blanking the card over a transient failure.
            debugLog("[rate-limit] claude probe failed (\(error)) — keeping cached snapshot")
            guard !Task.isCancelled, appState.claudeRateLimitEnabled else { return }
            if currentSnapshot(.claudeCode)?.status != .ok {
                upsert(ProviderRateLimit(provider: .claudeCode, status: .noData, fetchedAt: Date()))
            }
        }
        guard !Task.isCancelled else { return }
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

    /// Refresh everything currently visible, in parallel — the Codex leg now
    /// includes a network round-trip, so serializing would double the wait.
    func refreshAll() async {
        async let codex: Void = refreshCodex()
        async let claude: Void = refreshClaude()
        _ = await (codex, claude)
    }

    /// Ensure every enabled provider has a placeholder entry so the card row
    /// renders its loading state on a cold open instead of appearing empty.
    func seedPlaceholders() {
        for provider in [ProviderRateLimit.Provider.codex, .claudeCode] {
            let enabled = provider == .codex
                ? appState?.codexRateLimitEnabled == true
                : appState?.claudeRateLimitEnabled == true
            guard enabled,
                  appState?.rateLimits.contains(where: { $0.provider == provider }) != true
            else { continue }
            upsert(ProviderRateLimit(provider: provider, status: .noData, fetchedAt: nil))
        }
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
