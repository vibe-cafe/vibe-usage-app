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
    func start() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.refreshInterval))
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Fetch both providers concurrently and update AppState. Safe to call any time.
    func refresh() async {
        async let codex = Task.detached(priority: .userInitiated) {
            CodexRateLimitReader.read()
        }.value
        async let claude = ClaudeRateLimitReader.read()

        let results = await [codex, claude]
        appState?.rateLimits = results
    }
}
