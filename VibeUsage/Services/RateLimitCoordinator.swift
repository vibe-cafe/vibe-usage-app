import Foundation

/// Drives periodic rate-limit refresh across providers and pushes results into AppState.
///
/// All work is local: Codex reads files, Claude calls the OAuth usage API directly.
/// Nothing is uploaded to the Vibe Usage backend.
@MainActor
final class RateLimitCoordinator {
    private weak var appState: AppState?
    private var task: Task<Void, Never>?
    private let refreshInterval: TimeInterval

    init(appState: AppState, refreshInterval: TimeInterval = 300) {
        self.appState = appState
        self.refreshInterval = refreshInterval
    }

    /// Start the background refresh loop. Cancels the previous loop if any.
    /// Only Codex is touched automatically — Claude reads cross the keychain
    /// boundary which can re-prompt after every app re-signing, so we limit
    /// Claude fetches to explicit user actions (enable button, retry button,
    /// footer refresh).
    func start() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await self.refreshCodex()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.refreshInterval))
                if Task.isCancelled { break }
                await self.refreshCodex()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Refresh only Codex. Free, file-based, no prompts. Safe to call from any code path.
    func refreshCodex() async {
        let codex = await Task.detached(priority: .userInitiated) {
            CodexRateLimitReader.read()
        }.value
        upsert(codex)
    }

    /// Refresh only Claude. Triggers keychain read on first call after re-signing.
    /// Must be invoked from a user-initiated context. If the user has not enabled
    /// Claude monitoring yet, this is a no-op that surfaces the disabled placeholder.
    func refreshClaude() async {
        let enabled = appState?.claudeRateLimitEnabled == true
        debugLog("[rate-limit] refreshClaude() entered, enabled=\(enabled)")
        guard enabled else {
            upsert(ProviderRateLimit(provider: .claudeCode, status: .disabled, fetchedAt: nil))
            return
        }
        let snapshot = await ClaudeRateLimitReader.read()
        debugLog("[rate-limit] refreshClaude() got snapshot status=\(snapshot.status)")
        upsert(snapshot)
    }

    /// Refresh everything currently visible. Use sparingly — only from user-initiated
    /// actions that explicitly want Claude data (footer refresh, retry buttons).
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
