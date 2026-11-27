import Foundation

/// What a new-panel usage card shows for the selected period, one rule for
/// 近期消耗 and the details cards (maintainer, 2026-11-27). Only the
/// current period's successful read draws figures, and only it draws a zero.
enum UsageFigures {
    /// A snapshot to draw. `faded`: the previous period's figures while the
    /// new period's read runs (134r), kept only until that read ends.
    case figures(UsageDisplaySnapshot, faded: Bool)
    /// Being read, nothing to show yet: loading blocks (134q).
    case loading
    /// The read ended without figures for this period: 「—」, never 0.
    case unavailable

    /// - Parameters:
    ///   - current: the snapshot of the selected period, if its read succeeded.
    ///   - retained: the last snapshot drawn for this account.
    ///   - isLoading: a read is running.
    ///   - hasFinishedRead: a read for this account has ended (either way).
    static func resolve(current: UsageDisplaySnapshot?, retained: UsageDisplaySnapshot?,
                        isLoading: Bool, hasFinishedRead: Bool) -> UsageFigures {
        if let current { return .figures(current, faded: false) }
        if isLoading { return retained.map { .figures($0, faded: true) } ?? .loading }
        return hasFinishedRead ? .unavailable : .loading
    }
}

/// Keeps the last snapshot a card drew, for the faded figures of a period
/// change, and forgets it when the account or server changes. Not observed:
/// a view may call it from `body`.
@MainActor
final class UsageFiguresKeeper {
    private var retained: UsageDisplaySnapshot?
    private var account: UInt?

    func figures(_ appState: AppState, filters: UsagePanelFilters, now: Date = Date()) -> UsageFigures {
        if account != appState.usageAccount {
            account = appState.usageAccount
            retained = nil
        }
        let current = appState.usageDisplaySnapshot(filters: filters, now: now)
        if let current { retained = current }
        let figures = UsageFigures.resolve(current: current, retained: retained, isLoading: appState.isLoadingData,
                                           hasFinishedRead: appState.hasLoadedUsageData)
        // The new period's read ended without figures: the faded ones are
        // done, and a retry shows loading blocks until its answer.
        if case .unavailable = figures { retained = nil }
        return figures
    }
}
