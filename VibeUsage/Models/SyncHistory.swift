import Foundation

/// One sync as the app saw it, kept so a user can copy a diagnostic summary
/// that covers the last few runs (approved 2026-11-09 with the diagnostics
/// plan, revision 2: release builds may keep the last 10 summaries locally).
///
/// Only typed fields: when, who started it, how it ended, how long it took and
/// one fixed reason. Never the CLI's stdout/stderr, a server body, a path, or a
/// key. The 120s timeout lives in the app, so only the app can record it — the
/// CLI is killed before it could write anything itself.
struct SyncRecord: Codable, Equatable, Sendable {
    enum Trigger: String, Codable, Sendable {
        /// The 30-minute timer.
        case scheduled
        /// The run started when the scheduler starts (launch, new Key).
        case launch
        /// The user asked for it (footer refresh, Settings changes).
        case manual
    }

    enum Result: String, Codable, Sendable {
        case success
        case failure
        /// The app's 120s deadline ended the CLI.
        case timedOut
        /// The CLI never ran: no runtime, the process could not start, or the
        /// package launcher (`bun x` / `npx`) failed before the CLI's own code.
        case launchFailed
    }

    enum Reason: String, Codable, Sendable {
        case runtimeMissing
        case processNotStarted
        case launcherFailed
        case keyRejected
        case serverError
        case network
        case cliCrashed
        case other
    }

    var startedAt: Date
    var duration: TimeInterval
    var trigger: Trigger
    var result: Result
    var reason: Reason?
    /// Only for `.serverError`: the HTTP status number, never the body.
    var httpStatus: Int?
    /// Only for `.other`: the process exit code.
    var exitCode: Int32?
}

/// The last `limit` sync summaries in the app's own preferences, newest first.
/// Rolling: an append past the limit drops the oldest. Removed with the app's
/// data (Settings 「重置配置」, or deleting the app's preferences).
struct SyncHistoryStore {
    static let key = "diagnosticsSyncHistory.v1"
    static let limit = 10

    let defaults: UserDefaults

    func records() -> [SyncRecord] {
        guard let data = defaults.data(forKey: Self.key),
              let records = try? JSONDecoder().decode([SyncRecord].self, from: data)
        else { return [] }
        return Array(records.prefix(Self.limit))
    }

    func append(_ record: SyncRecord) {
        let next = Array(([record] + records()).prefix(Self.limit))
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
