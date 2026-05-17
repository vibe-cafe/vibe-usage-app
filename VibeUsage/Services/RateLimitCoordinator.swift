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

    init(appState: AppState) {
        self.appState = appState
    }

    /// Refresh Codex unconditionally. Free, file-based, no prompts.
    /// Used by the manual "更新数据" path; popover-open should prefer the
    /// debounced `refreshCodexIfNeeded` to avoid repeat work on rapid open/close.
    func refreshCodex() async {
        let codex = await Task.detached(priority: .userInitiated) {
            CodexRateLimitReader.read()
        }.value
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
    /// cheap. If the user hasn't enabled capture yet, surface the disabled
    /// placeholder (the card's "启用" button installs the hook).
    func refreshClaude() async {
        let enabled = appState?.claudeRateLimitEnabled == true
        debugLog("[rate-limit] refreshClaude() entered, enabled=\(enabled)")
        guard enabled else {
            upsert(ProviderRateLimit(provider: .claudeCode, status: .disabled, fetchedAt: nil))
            return
        }
        let snapshot = await Task.detached(priority: .userInitiated) {
            ClaudeRateLimitReader.read()
        }.value
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

    /// Ensure both providers have at least a placeholder entry so the UI renders
    /// the disabled / enable affordance for Claude on first launch.
    func seedPlaceholders() {
        if appState?.rateLimits.contains(where: { $0.provider == .codex }) != true {
            upsert(ProviderRateLimit(provider: .codex, status: .noData, fetchedAt: nil))
        }
        if appState?.rateLimits.contains(where: { $0.provider == .claudeCode }) != true {
            upsert(ProviderRateLimit(provider: .claudeCode, status: .disabled, fetchedAt: nil))
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
