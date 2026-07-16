import Foundation

/// Refreshes rate-limit snapshots on demand and pushes results into AppState.
///
/// Codex is network-first: `CodexUsageAPI` reads the zero-quota usage endpoint
/// with the CLI's own OAuth token (a plain-file read — no prompts), falling
/// back to the session-JSONL scan when offline or logged out. Claude stays a
/// pure local read of the statusline-capture file written by `StatuslineHook`.
/// Nothing is uploaded to the Vibe Usage backend. There is no background
/// timer — refreshes are driven by popover-open (debounced), user-initiated
/// actions, and (while the popover is visible) a watcher on the Claude capture
/// directory so a statusline render updates the card live.
@MainActor
final class RateLimitCoordinator {
    private weak var appState: AppState?
    private var lastCodexFetchAt: Date?
    private var lastClaudeFetchAt: Date?
    private var claudeCaptureWatcher: DirectoryWatcher?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Refresh Codex unconditionally: live endpoint first, JSONL fallback.
    /// Used by the manual "更新数据" path; popover-open should prefer the
    /// debounced `refreshCodexIfNeeded` to avoid repeat work on rapid open/close.
    func refreshCodex() async {
        guard let appState, appState.codexRateLimitEnabled else { return }
        appState.isCodexRateLimitRefreshing = true
        defer { appState.isCodexRateLimitRefreshing = false }

        // Instant paint: if nothing usable is on screen yet, surface the local
        // JSONL snapshot first so the card doesn't sit empty for the ~1s the
        // network round-trip takes. The live result replaces it right after.
        if currentSnapshot(.codex)?.status != .ok {
            let cached = await Self.readCodexSessionFiles()
            if cached.status == .ok { upsert(cached) }
        }

        do {
            upsert(try await CodexUsageAPI.fetch())
        } catch is CancellationError {
            return
        } catch CodexUsageAPI.FetchError.unauthorized {
            // Token rejected even after re-reading auth.json — the user really
            // is logged out of Codex. Stale JSONL data (if any) still renders,
            // with its 「数据截至」 note; otherwise surface the re-login state.
            debugLog("[rate-limit] codex live fetch unauthorized — user logged out of Codex CLI")
            let cached = await Self.readCodexSessionFiles()
            if cached.status == .ok {
                upsert(cached)
            } else {
                upsert(ProviderRateLimit(provider: .codex, status: .unauthorized, fetchedAt: Date()))
            }
        } catch {
            // Offline / endpoint drift → degrade to exactly the pre-network
            // behavior: whatever the session JSONL has. If the JSONL has
            // nothing but a previous live snapshot is still on screen, keep
            // it — its 「数据截至」 note communicates the age honestly, which
            // beats collapsing the card over a transient network blip.
            debugLog("[rate-limit] codex live fetch failed (\(error)) — falling back to session JSONL")
            let cached = await Self.readCodexSessionFiles()
            if cached.status == .ok || currentSnapshot(.codex)?.status != .ok {
                upsert(cached)
            }
        }
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

    /// Refresh Claude from the local statusline-capture file. Auth-free and
    /// cheap; only runs while Claude monitoring is enabled.
    func refreshClaude() async {
        guard let appState, appState.claudeRateLimitEnabled else { return }
        appState.isClaudeRateLimitRefreshing = true
        defer { appState.isClaudeRateLimitRefreshing = false }
        debugLog("[rate-limit] refreshClaude() entered")
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

    /// Refresh everything currently visible, in parallel — the Codex leg now
    /// includes a network round-trip, so serializing would double the wait.
    func refreshAll() async {
        async let codex: Void = refreshCodex()
        async let claude: Void = refreshClaude()
        _ = await (codex, claude)
    }

    /// Ensure both providers have at least a placeholder entry so the UI renders
    /// the disabled / enable affordance for Claude on first launch.
    func seedPlaceholders() {
        if appState?.codexRateLimitEnabled == true,
           appState?.rateLimits.contains(where: { $0.provider == .codex }) != true {
            upsert(ProviderRateLimit(provider: .codex, status: .noData, fetchedAt: nil))
        }
        if appState?.claudeRateLimitEnabled == true,
           appState?.rateLimits.contains(where: { $0.provider == .claudeCode }) != true {
            upsert(ProviderRateLimit(provider: .claudeCode, status: .disabled, fetchedAt: nil))
        }
    }

    // MARK: - Live capture watching (popover visible only)

    /// While the popover is visible, watch `~/.vibe-usage` so a Claude Code
    /// statusline render (the wrapper rewrites the capture file via mv, i.e. a
    /// directory-entry change) updates the card live instead of waiting for
    /// the next open. Codex needs no equivalent — its live source is the
    /// endpoint, refreshed on open.
    func panelVisibilityChanged(visible: Bool) {
        guard visible else {
            claudeCaptureWatcher?.stop()
            claudeCaptureWatcher = nil
            return
        }
        guard appState?.claudeRateLimitEnabled == true, claudeCaptureWatcher == nil else { return }
        let watcher = DirectoryWatcher { [weak self] in
            Task { await self?.refreshClaude() }
        }
        watcher.start(directory: StatuslineHook.rateLimitFileURL.deletingLastPathComponent())
        claudeCaptureWatcher = watcher
    }

    // MARK: - Helpers

    private nonisolated static func readCodexSessionFiles() async -> ProviderRateLimit {
        await Task.detached(priority: .userInitiated) {
            CodexRateLimitReader.read()
        }.value
    }

    private func currentSnapshot(_ provider: ProviderRateLimit.Provider) -> ProviderRateLimit? {
        appState?.rateLimits.first { $0.provider == provider }
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
