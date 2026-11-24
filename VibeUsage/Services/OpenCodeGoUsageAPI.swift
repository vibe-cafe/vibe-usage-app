import Foundation
import SQLite3

/// Live OpenCode Go subscription quota.
///
/// `GET https://opencode.ai/zen/go/v1/usage` is the account-wide endpoint
/// OpenCode itself reads for the Go allowance. It authenticates with the login
/// OpenCode already saved on this Mac, in the directory we already scan for
/// local discovery, so there is no keychain prompt and no extra permission —
/// the same reasoning that keeps the Codex leg on `~/.codex/auth.json`.
///
/// Where that login lives depends on the OpenCode generation and how the user
/// connected (checked against anomalyco/opencode v1.19.6 and v2.4.1):
/// - 2.x keeps logins in the `credential` table of `opencode.db`: an
///   `opencode-go` row holds a Go API key; an `opencode` row holds either an
///   OpenCode account sign-in (`oauth`: an access token plus the workspace it
///   chose) or a service-account key. Since OpenCode 2.4.0 the `opencode` row
///   is the only connect option new users see, and Go comes through it.
/// - 1.x keeps them in `auth.json`: `opencode-go` when the user connected
///   "OpenCode Go" (the official Go docs), `opencode` when they connected
///   "OpenCode" with the same workspace key.
///
/// The endpoint is the *only* source for these numbers: OpenCode writes
/// per-message token accounting into its own SQLite store, but the Go plan's
/// dollar-denominated windows (rolling 5h / weekly / monthly, reported as a
/// percentage consumed) exist solely server-side. The request consumes no
/// credit and is safe to repeat.
///
/// A login without the Go entitlement (Zen free tier, API-key-only) answers 403
/// `EntitlementError`. That is a fact about the account, not a read failure, so
/// it maps to `.notApplicable` and the card states the subscription is missing
/// instead of offering a retry that can never succeed.
///
/// The credential never leaves this type: it is read per request, sent only in
/// the `Authorization` header (with the workspace ID beside an account
/// sign-in, as OpenCode sends it), and never logged, cached, or written
/// anywhere. An account sign-in is never renewed here: renewal rewrites
/// OpenCode's credential and rotates its refresh token, and racing OpenCode's
/// own renewal can sign the user out of OpenCode. OpenCode renews it whenever
/// it runs. The response body is reduced to percentages and reset instants
/// before it leaves `parseUsageResponse`.
enum OpenCodeGoUsageAPI {

    /// Why a live fetch produced no snapshot. Mirrors `CodexUsageAPI.FetchError`
    /// so the coordinator can treat every native provider the same way.
    enum FetchError: RateLimitFetchError {
        case notLoggedIn        // no usable OpenCode login in any store
        case signInExpired      // an OpenCode account sign-in whose token lapsed
        case unauthorized       // 401 even after re-reading the stores
        case notSubscribed      // 403: this account has no OpenCode Go plan
        case transport(Error)   // offline, DNS failure, timeout
        case badResponse(Int)   // non-200 that survived the retry policy
        case unparseable        // 200 but not a JSON shape we recognize

        var rateLimitFailure: RateLimitFetchFailure {
            switch self {
            // Nothing a retry here can change: the user logs in, or opens
            // OpenCode so it renews its sign-in, and the next refresh reads it.
            case .notLoggedIn, .signInExpired: return .absent
            case .unauthorized: return .unauthorized
            case .notSubscribed: return .notApplicable
            case .transport, .badResponse, .unparseable: return .transient
            }
        }

        var liveFailure: ProviderRateLimit.LiveFailure? {
            switch self {
            case .notLoggedIn: return .credentialsNotFound
            case .signInExpired: return .credentialsExpired
            case .unauthorized: return .credentialsRejected
            // A definitive answer, carried as `EmptyReason.notEntitled`.
            case .notSubscribed: return nil
            case let .transport(error): return .transport(error)
            case let .badResponse(status): return .endpointHTTPStatus(status)
            case .unparseable: return .endpointUnrecognized
            }
        }
    }

    // MARK: - Credentials

    /// What the usage request needs: a bearer token and, for an OpenCode
    /// account login, the workspace it chose.
    struct Credential: Equatable {
        var token: String
        var workspaceID: String?
    }

    /// One store's answer for one integration.
    enum Lookup: Equatable {
        case found(Credential)
        case expired
        case missing
    }

    static let goIntegrationID = "opencode-go"
    static let openCodeIntegrationID = "opencode"

    /// OpenCode renews an account token five minutes before it lapses whenever
    /// it runs; a token this close to its expiry is treated as expired.
    static let expiryMargin: TimeInterval = 60

    /// OpenCode's data home: `$XDG_DATA_HOME/opencode`, else
    /// `~/.local/share/opencode`, exactly as OpenCode resolves it.
    static var dataHome: URL {
        dataHome(environment: ProcessInfo.processInfo.environment)
    }

    static func dataHome(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("opencode", isDirectory: true)
        }
        return home.appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    static var authFileURL: URL {
        dataHome.appendingPathComponent("auth.json")
    }

    static var credentialDatabaseURL: URL {
        dataHome.appendingPathComponent("opencode.db")
    }

    /// Every store, in the order the CLI's adapter tries them: the 2.x
    /// credential table (`opencode-go`, then `opencode`), then 1.x `auth.json`
    /// (`opencode-go`, then `opencode`). The first usable login wins; an
    /// expired account sign-in is reported only when nothing else is usable.
    static func loadCredential(dataHome: URL = OpenCodeGoUsageAPI.dataHome, now: Date = Date()) -> Lookup {
        let table = loadCredentialTable(databaseURL: dataHome.appendingPathComponent("opencode.db"), now: now)
        let file = loadAuthFile(authFileURL: dataHome.appendingPathComponent("auth.json"), now: now)
        let lookups = table + file
        for case let .found(credential) in lookups { return .found(credential) }
        return lookups.contains(.expired) ? .expired : .missing
    }

    private static func loadAuthFile(authFileURL: URL, now: Date) -> [Lookup] {
        guard let data = try? Data(contentsOf: authFileURL) else { return [] }
        return parseAuthFile(data, now: now)
    }

    /// auth.json shape: `{"opencode-go": {"type": "api", "key": "sk-..."},
    /// "opencode": {...}, ...}`. Only those two entries are read; other entries
    /// are provider credentials for third-party models and are never inspected.
    static func parseAuthFile(_ data: Data, now: Date = Date()) -> [Lookup] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return [goIntegrationID, openCodeIntegrationID].compactMap { id in
            guard let entry = obj[id] else { return nil }
            // 1.x stores API keys as `{ type: "api", key }`; an OAuth entry
            // there carries no workspace and is not a Go login.
            guard let entry = entry as? [String: Any], entry["type"] as? String == "api" else { return .missing }
            return credential(from: entry, integrationID: id, now: now)
        }
    }

    /// The credential-table query: the `opencode-go` and `opencode` rows, one
    /// column each. `active` is nullable in the store's own schema, so it is
    /// coalesced before ordering, and the newest row wins among equally active
    /// ones — the same rows the CLI's adapter picks.
    static let credentialQuery = """
        SELECT integration_id, value FROM credential
        WHERE integration_id IN ('opencode-go', 'opencode')
        ORDER BY coalesce(active, 1) DESC, time_updated DESC
        """

    /// Reads the current row of each integration from a read-only connection.
    /// Any failure — no database, an older schema without the table, a lock,
    /// a malformed blob — yields no lookup so the caller falls back to
    /// `auth.json` instead of reporting a missing login.
    static func loadCredentialTable(
        databaseURL: URL = credentialDatabaseURL,
        now: Date = Date()
    ) -> [Lookup] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return []
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, credentialQuery, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        var current: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: rawID)
            guard current[id] == nil else { continue }
            current[id] = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        }
        return [goIntegrationID, openCodeIntegrationID].compactMap { id in
            guard let raw = current[id] else { return nil }
            guard let data = raw.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .missing }
            return credential(from: value, integrationID: id, now: now)
        }
    }

    /// Turns one stored value into a usable credential. Only the key, or an
    /// account sign-in's access token, expiry, Console and workspace ID are
    /// read; the refresh token is never touched.
    static func credential(from value: [String: Any], integrationID: String, now: Date) -> Lookup {
        let metadata = value["metadata"] as? [String: Any]
        // Only an OpenCode-account credential names a workspace for the
        // request; a Go key is already scoped to one and is sent as before.
        let workspaceID = integrationID == openCodeIntegrationID
            ? (metadata?["orgID"] as? String).flatMap(normalizedKey) : nil
        switch value["type"] as? String {
        case "key", "api":
            guard let key = (value["key"] as? String).flatMap(normalizedKey) else { return .missing }
            return .found(Credential(token: key, workspaceID: workspaceID))
        case "oauth" where integrationID == openCodeIntegrationID:
            // OpenCode reads the workspace from the sign-in itself and shows
            // no Go usage without it.
            guard let access = (value["access"] as? String).flatMap(normalizedKey),
                  let workspaceID,
                  isDefaultConsole(metadata?["server"] as? String)
            else { return .missing }
            let expires = number(value["expires"]) ?? 0
            if expires != 0, expires / 1000 <= now.timeIntervalSince1970 + expiryMargin {
                return .expired
            }
            return .found(Credential(token: access, workspaceID: workspaceID))
        default:
            return .missing
        }
    }

    /// An account sign-in is accepted only for the default OpenCode Console
    /// (the retired host maps onto it, as OpenCode rewrites it); a custom
    /// Console's token belongs to another server.
    static func isDefaultConsole(_ server: String?) -> Bool {
        guard let server = server?.trimmingCharacters(in: .whitespacesAndNewlines), !server.isEmpty else {
            return true
        }
        guard let url = URL(string: server), url.scheme == "https", url.port == nil else { return false }
        return url.host == "opencode.ai" || url.host == "console.opencode.ai"
    }

    private static func normalizedKey(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Fetch

    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    static func fetch(now: Date = Date()) async throws -> ProviderRateLimit {
        var credential: Credential
        switch loadCredential(now: now) {
        case let .found(found): credential = found
        case .expired: throw FetchError.signInExpired
        case .missing: throw FetchError.notLoggedIn
        }

        var (data, status) = try await send(credential)

        // OpenCode can rotate the key or renew its sign-in at any time; a 401
        // usually means our copy is stale rather than that the plan lapsed.
        // Re-read the stores once and retry — the app never rewrites
        // OpenCode's credential.
        if status == 401, case let .found(fresh) = loadCredential(now: Date()), fresh != credential {
            credential = fresh
            (data, status) = try await send(fresh)
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

    /// The request for one credential: the bearer token, and the workspace an
    /// OpenCode account login chose, as OpenCode sends it for the same request.
    static func request(for credential: Credential) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeUsage/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")
        if let workspaceID = credential.workspaceID {
            request.setValue(workspaceID, forHTTPHeaderField: "x-opencode-org-id")
        }
        return request
    }

    // MARK: - Transport

    private static let maxAttempts = 3
    private static let requestTimeout: TimeInterval = 10

    private static func send(_ credential: Credential) async throws -> (Data, Int) {
        let request = request(for: credential)

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
                // Pinned to the system route for this URL: a proxy that is
                // down fails the request instead of letting it go direct.
                let (data, response) = try await SystemProxy.data(for: request)
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
            emptyReason: meters.isEmpty ? .noWindow : nil,
            source: .live
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
