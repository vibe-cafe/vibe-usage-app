import Foundation

/// Refreshes rate-limit snapshots on demand and pushes results into AppState.
///
/// All work is local file reads: Codex parses its session JSONL, Claude reads
/// the statusline-capture file written by `StatuslineHook`. Nothing is uploaded
/// to the Vibe Usage backend. There is no background timer — refreshes are
/// driven by popover-open (debounced) and user-initiated actions.
@MainActor
final class RateLimitCoordinator {
    private weak var appState: AppState?
    private var lastCodexFetchAt: Date?
    private var lastClaudeFetchAt: Date?

    /// Both reads are local-file scans that should complete in well under a
    /// second; these are a safety net against a pathological filesystem (e.g.
    /// a network-mounted home directory) hanging the UI in "loading" forever
    /// rather than a tuned budget for the happy path.
    private static let codexTimeout: TimeInterval = 6
    private static let claudeTimeout: TimeInterval = 3

    init(appState: AppState) {
        self.appState = appState
    }

    /// Refresh Codex unconditionally. Free, file-based, no prompts.
    /// Used by the manual "更新数据" path; popover-open should prefer the
    /// debounced `refreshCodexIfNeeded` to avoid repeat work on rapid open/close.
    func refreshCodex() async {
        guard appState?.codexRateLimitEnabled == true else { return }
        markFetching(.codex, true)
        let codex = await Self.withTimeout(Self.codexTimeout) {
            // Prefer the live API (fresher windows + the only source of the
            // reset-credit count). Fall back to the local session-file walk when
            // the token/network isn't available so the card still works offline.
            if let api = await CodexUsageAPIReader.fetch() {
                return api
            }
            debugLog("[rate-limit] codex API unavailable — falling back to local session files")
            return await Task.detached(priority: .userInitiated) {
                CodexRateLimitReader.read()
            }.value
        } onTimeout: {
            ProviderRateLimit(provider: .codex, status: .error("读取超时，请重试"), fetchedAt: Date())
        }
        upsert(codex)
        lastCodexFetchAt = Date()
    }

    /// Refresh Codex only if we haven't refreshed within `maxAge` seconds.
    /// Mirrors `fetchUsageDataIfNeeded` so popover-open doesn't hammer the
    /// session-file walk when the user toggles the popover repeatedly.
    func refreshCodexIfNeeded(maxAge: TimeInterval = 60) async {
        if let last = lastCodexFetchAt, Date().timeIntervalSince(last) < maxAge {
            return
        }
        await refreshCodex()
    }

    /// Refresh Claude from the local statusline-capture file. Auth-free and
    /// cheap; only runs while Claude monitoring is enabled.
    func refreshClaude() async {
        guard appState?.claudeRateLimitEnabled == true else { return }
        debugLog("[rate-limit] refreshClaude() entered")
        markFetching(.claudeCode, true)
        let snapshot = await Self.withTimeout(Self.claudeTimeout) {
            await Task.detached(priority: .userInitiated) {
                ClaudeRateLimitReader.read()
            }.value
        } onTimeout: {
            ProviderRateLimit(provider: .claudeCode, status: .error("读取超时，请重试"), fetchedAt: Date())
        }
        debugLog("[rate-limit] refreshClaude() got snapshot status=\(snapshot.status)")
        upsert(snapshot)
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

    /// Refresh everything currently visible. Cheap (two local-file reads).
    func refreshAll() async {
        await refreshCodex()
        await refreshClaude()
    }

    /// Ensure both providers have at least a placeholder entry so the card
    /// renders instantly on first launch — `.loading` rather than `.noData` /
    /// `.disabled`, since a refresh is about to run and we don't want the
    /// card to flash "no data" and then pop into existence a moment later.
    func seedPlaceholders() {
        if appState?.codexRateLimitEnabled == true,
           appState?.rateLimits.contains(where: { $0.provider == .codex }) != true {
            upsert(ProviderRateLimit(provider: .codex, status: .loading, fetchedAt: nil, isFetching: true))
        }
        if appState?.claudeRateLimitEnabled == true,
           appState?.rateLimits.contains(where: { $0.provider == .claudeCode }) != true {
            upsert(ProviderRateLimit(provider: .claudeCode, status: .loading, fetchedAt: nil, isFetching: true))
        }
    }

    /// Mark a provider as "refresh in flight" without disturbing its existing
    /// status/data — a background refresh (popover reopened, manual retry)
    /// should keep showing the last-known numbers, just with a subtle
    /// in-progress indicator, rather than reverting to a loading skeleton.
    /// Only seeds a fresh `.loading` placeholder when no entry exists yet.
    private func markFetching(_ provider: ProviderRateLimit.Provider, _ fetching: Bool) {
        guard let appState else { return }
        var current = appState.rateLimits
        if let i = current.firstIndex(where: { $0.provider == provider }) {
            current[i].isFetching = fetching
            appState.rateLimits = current
        } else if fetching {
            upsert(ProviderRateLimit(provider: provider, status: .loading, isFetching: true))
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

    /// Race `operation` against a `seconds` timer; whichever finishes first
    /// wins and the loser is cancelled. Keeps a stalled local-file read from
    /// leaving the UI stuck in "loading" indefinitely.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T,
        onTimeout: @escaping @Sendable () -> T
    ) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return onTimeout()
            }
            let result = await group.next() ?? onTimeout()
            group.cancelAll()
            return result
        }
    }
}
