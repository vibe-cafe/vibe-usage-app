import Foundation
import SQLite3

/// Live OpenCode Go subscription quota.
///
/// `GET https://opencode.ai/zen/go/v1/usage` is the account-wide endpoint the
/// OpenCode CLI's own usage view reads. It authenticates with the API key the
/// CLI already stores as plain text in `~/.local/share/opencode/auth.json`
/// (`opencode.key`) — a file in the directory we already scan for local
/// discovery, so there is no keychain prompt and no extra permission, the same
/// reasoning that keeps the Codex leg on `~/.codex/auth.json`.
///
/// The endpoint is the *only* source for these numbers: OpenCode writes
/// per-message token accounting into its own SQLite store, but the Go plan's
/// dollar-denominated windows (rolling 5h / weekly / monthly, reported as a
/// percentage consumed) exist solely server-side. The request consumes no
/// credit and is safe to repeat.
///
/// A key without the Go entitlement (Zen free tier, API-key-only) answers 403
/// `EntitlementError`. That is a fact about the account, not a read failure, so
/// it maps to `.notApplicable` and the card states the subscription is missing
/// instead of offering a retry that can never succeed.
///
/// The key never leaves this type: it is read per request, sent only in the
/// `Authorization` header, and never logged, cached, or written anywhere. The
/// response body is reduced to percentages and reset instants before it leaves
/// `parseUsageResponse`.
enum OpenCodeGoUsageAPI {

    /// Why a live fetch produced no snapshot. Mirrors `CodexUsageAPI.FetchError`
    /// so the coordinator can treat every native provider the same way.
    enum FetchError: RateLimitFetchError {
        case notLoggedIn        // no auth.json / no `opencode` key entry
        case unauthorized       // 401 even after re-reading auth.json
        case notSubscribed      // 403: this account has no OpenCode Go plan
        case transport(Error)   // offline, DNS failure, timeout
        case badResponse(Int)   // non-200 that survived the retry policy
        case unparseable        // 200 but not a JSON shape we recognize

        var rateLimitFailure: RateLimitFetchFailure {
            switch self {
            case .notLoggedIn: return .absent
            case .unauthorized: return .unauthorized
            case .notSubscribed: return .notApplicable
            case .transport, .badResponse, .unparseable: return .transient
            }
        }
    }

    // MARK: - Credentials

    /// OpenCode's data home. The CLI resolves the same fixed path (it does not
    /// consult `XDG_DATA_HOME`), so a probe that guessed a different location
    /// would read a different account than the one syncs report on.
    static var dataHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    static var authFileURL: URL {
        dataHome.appendingPathComponent("auth.json")
    }

    static var credentialDatabaseURL: URL {
        dataHome.appendingPathComponent("opencode.db")
    }

    /// The Go key lives in two places depending on the OpenCode generation, and
    /// the probe reads both: the event-sourced `credential` table first, because
    /// its `opencode-go` row is the Go-*specific* record, then `auth.json`, which
    /// is where the pre-2.x layout keeps the same key. Only the key is ever
    /// read; neither source is written back.
    static func loadAPIKey(dataHome: URL = OpenCodeGoUsageAPI.dataHome) -> String? {
        loadCredentialTableKey(databaseURL: dataHome.appendingPathComponent("opencode.db"))
            ?? loadAuthFileKey(authFileURL: dataHome.appendingPathComponent("auth.json"))
    }

    private static func loadAuthFileKey(authFileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: authFileURL) else { return nil }
        return parseAuthFile(data)
    }

    /// auth.json shape: `{"opencode": {"type": "api", "key": "sk-..."}, ...}`.
    /// Other entries are provider credentials for third-party models and are
    /// never inspected.
    static func parseAuthFile(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = obj["opencode"] as? [String: Any],
              let key = entry["key"] as? String
        else { return nil }
        return normalizedKey(key)
    }

    /// The credential-table query: one row, one column. `active` is nullable in
    /// the store's own schema, so it is coalesced before ordering, and the newest
    /// row wins among equally active ones — the same row the CLI's adapter picks.
    static let credentialQuery = """
        SELECT value FROM credential
        WHERE integration_id = 'opencode-go'
        ORDER BY coalesce(active, 1) DESC, time_updated DESC
        LIMIT 1
        """

    /// Reads only that row's `value` (`{"type":"key","key":"sk-..."}`) from a
    /// read-only connection. Any failure — no database, an older schema without
    /// the table, a lock, a malformed blob — returns nil so the caller falls
    /// back to `auth.json` instead of reporting a missing login.
    static func loadCredentialTableKey(
        databaseURL: URL = credentialDatabaseURL,
        query: String = credentialQuery
    ) -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0)
        else { return nil }

        guard let data = String(cString: raw).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["key"] as? String
        else { return nil }
        return normalizedKey(key)
    }

    private static func normalizedKey(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Fetch

    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    static func fetch(now: Date = Date()) async throws -> ProviderRateLimit {
        guard var key = loadAPIKey() else { throw FetchError.notLoggedIn }

        var (data, status) = try await send(token: key)

        // The CLI can rotate this key from its own `/login`; a 401 usually means
        // our copy is stale rather than that the plan lapsed. Re-read the file
        // once and retry — the app never rewrites OpenCode's credential.
        if status == 401, let fresh = loadAPIKey(), fresh != key {
            key = fresh
            (data, status) = try await send(token: fresh)
        }
        if status == 401 { throw FetchError.unauthorized }
        if status == 403 { throw FetchError.notSubscribed }
        guard status == 200 else { throw FetchError.badResponse(status) }

        guard let snapshot = parseUsageResponse(data, now: now) else {
            throw FetchError.unparseable
        }
        try Task.checkCancellation()
        return snapshot
    }

    // MARK: - Transport

    private static let maxAttempts = 3
    private static let requestTimeout: TimeInterval = 10

    private static func send(token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeUsage/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")

        var lastError: Error?
        var lastStatus = 0
        var lastData = Data()
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                // 0.5s / 1s exponential backoff, matching the Codex leg. A
                // cancelled sleep (popover closed mid-fetch) aborts the fetch.
                try await Task.sleep(for: .milliseconds(500 * (1 << (attempt - 2))))
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !isRetryable(status: status) || attempt == maxAttempts {
                    return (data, status)
                }
                (lastData, lastStatus) = (data, status)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !isRetryable(error: error) || attempt == maxAttempts {
                    throw FetchError.transport(error)
                }
                lastError = error
            }
        }
        if let lastError { throw FetchError.transport(lastError) }
        return (lastData, lastStatus)
    }

    /// Retry 5xx and the request-timeout family; 4xx (including 401/403/429)
    /// are deterministic answers, not transient failures.
    private static func isRetryable(status: Int) -> Bool {
        status >= 500 || status == 408 || status == 425
    }

    private static func isRetryable(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    // MARK: - Response parsing

    /// The three windows the Go plan enforces, in display order.
    ///
    /// The payload carries no window *length*, so `windowDuration` is stated
    /// only where the length is fixed and documented: the rolling window is
    /// always 5 hours and the weekly window always 7 days (its `resetsAt` lands
    /// on a week boundary). The monthly window resets on a calendar-ish month
    /// that can be 28–31 days, and the card would draw a wrong "% time elapsed"
    /// bar from a guessed length — so it stays `nil` there and the row shows
    /// utilization plus reset time only.
    struct WindowSpec {
        var key: String
        var label: String
        var duration: TimeInterval?
    }

    static let windows: [WindowSpec] = [
        WindowSpec(key: "rolling", label: "5h", duration: 5 * 3600),
        WindowSpec(key: "weekly", label: "Weekly", duration: 7 * 86_400),
        WindowSpec(key: "monthly", label: "Monthly", duration: nil),
    ]

    /// A successful answer always has the shape
    /// `{"usage": {"rolling": {"status": "ok", "percent": 4, "resetsAt": "..."},
    ///             "weekly": {...}, "monthly": {...}}}`.
    /// Unknown keys are ignored, and a window whose `percent` is not a number
    /// is schema drift rather than "0% used" — that rejects the whole payload so
    /// the card never reports a confidently wrong number.
    static func parseUsageResponse(_ data: Data, now: Date = Date()) -> ProviderRateLimit? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // An explicitly empty `usage` object is the endpoint's own "no window
        // applies" answer; a missing `usage` key is a shape we don't know.
        guard let usage = obj["usage"] as? [String: Any] else { return nil }

        var meters: [RateLimitMeter] = []
        for spec in windows {
            guard let raw = usage[spec.key], !(raw is NSNull) else { continue }
            guard let dict = raw as? [String: Any],
                  let percent = number(dict["percent"])
            else { return nil }
            meters.append(RateLimitMeter(
                id: spec.key,
                label: spec.label,
                window: RateLimitWindow(
                    utilization: min(max(percent, 0), 100),
                    resetsAt: parseInstant(dict["resetsAt"]),
                    windowDuration: spec.duration
                )
            ))
        }

        return ProviderRateLimit(
            provider: .opencodeGo,
            meters: meters,
            status: meters.isEmpty ? .noData : .ok,
            fetchedAt: now,
            dataAsOf: now,
            // The endpoint answered, so "no window" is its own statement rather
            // than a read failure — the same distinction Codex's card makes.
            emptyReason: meters.isEmpty ? .noWindow : nil
        )
    }

    private static func number(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    /// `resetsAt` is an ISO-8601 instant, with or without fractional seconds.
    static func parseInstant(_ raw: Any?) -> Date? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
