import Foundation

/// Fetches Codex rate limits live from the zero-quota usage endpoint the
/// official Codex clients poll (`GET {base}/wham/usage`), authenticated with
/// the OAuth token the Codex CLI already keeps in `~/.codex/auth.json`.
///
/// This is the network-first upgrade over `CodexRateLimitReader`'s session-JSONL
/// scan: the JSONL only updates while Codex is actively running, so the card
/// went stale — or collapsed entirely once both windows' `resets_at` passed —
/// exactly when the user is idle and wondering "how much quota do I have left".
/// The endpoint consumes no quota and needs no extra permission: `auth.json`
/// is a plain file in a directory we already read (unlike Claude, whose token
/// lives in a keychain item — see commit 87e1061 for why that path was removed).
///
/// On top of freshness, the response carries facts the JSONL cannot provide:
/// the current plan, whether each window is *enforced at all* (OpenAI removed
/// the 5h window on 2026-07-12; a missing window in the JSONL is
/// indistinguishable from "no recent activity"), and available rate-limit
/// reset credits.
///
/// `CodexRateLimitReader` stays as the offline fallback: the coordinator paints
/// its snapshot instantly, then replaces it with the live response.
enum CodexUsageAPI {

    /// Why a live fetch produced no snapshot. The coordinator maps these to
    /// different fallbacks: `unauthorized` surfaces a re-login affordance,
    /// everything else silently degrades to the JSONL scan.
    enum FetchError: Error {
        case notLoggedIn        // no auth.json / no OAuth tokens (API-key-only login)
        case unauthorized       // token rejected even after re-reading auth.json
        case transport(Error)   // offline, DNS failure, timeout
        case badResponse(Int)   // non-200 that survived the retry policy
        case unparseable        // 200 but not a JSON shape we recognize
    }

    // MARK: - Fetch

    static func fetch(now: Date = Date()) async throws -> ProviderRateLimit {
        guard let auth = loadAuth() else { throw FetchError.notLoggedIn }

        var (data, status) = try await send(token: auth.accessToken, accountID: auth.accountID)

        // The CLI rotates this token routinely, so a 401 usually means our copy
        // is outdated, not that the user logged out. Re-read auth.json once and
        // retry. We deliberately do NOT run the OAuth refresh grant ourselves —
        // rewriting the CLI's credential file from a GUI app isn't worth the
        // risk, and the CLI refreshes on its own next run.
        if status == 401, let fresh = loadAuth(), fresh.accessToken != auth.accessToken {
            (data, status) = try await send(token: fresh.accessToken, accountID: fresh.accountID)
        }
        if status == 401 { throw FetchError.unauthorized }
        guard status == 200 else { throw FetchError.badResponse(status) }

        guard let snapshot = parseUsageResponse(data, now: now) else {
            throw FetchError.unparseable
        }
        cache(snapshot)
        return snapshot
    }

    // MARK: - Transport

    private static let maxAttempts = 3
    private static let requestTimeout: TimeInterval = 10

    private static func send(token: String, accountID: String?) async throws -> (Data, Int) {
        var request = URLRequest(url: usageURL())
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeUsage/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        var lastError: Error?
        var lastStatus = 0
        var lastData = Data()
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                // 0.5s / 1s exponential backoff between attempts; a cancelled
                // sleep (popover closed mid-fetch) aborts the whole fetch.
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

    /// Retry 5xx and the request-timeout family; 4xx (including 401/429) are
    /// deterministic answers, not transient failures.
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

    // MARK: - Credentials (~/.codex/auth.json)

    struct AuthInfo: Equatable {
        var accessToken: String
        var accountID: String?
    }

    /// Honor CODEX_HOME (some users relocate ~/.codex), mirroring the CLI.
    static var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    private static func loadAuth() -> AuthInfo? {
        guard let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")) else {
            return nil
        }
        return parseAuthFile(data)
    }

    /// auth.json shape: `{"tokens": {"access_token": "...", "account_id": "..."}}`.
    /// API-key-only logins have no `tokens` object — that's `nil` here (the
    /// usage endpoint is only meaningful for subscription auth; the JSONL
    /// fallback still covers those users).
    static func parseAuthFile(_ data: Data) -> AuthInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty
        else { return nil }
        return AuthInfo(accessToken: access, accountID: tokens["account_id"] as? String)
    }

    // MARK: - Endpoint URL

    private static let defaultBaseURL = "https://chatgpt.com/backend-api"

    private static func usageURL() -> URL {
        let configURL = codexHome.appendingPathComponent("config.toml")
        let configured = (try? String(contentsOf: configURL, encoding: .utf8))
            .flatMap(parseChatGPTBaseURL)
        return usageURL(base: configured ?? defaultBaseURL)
    }

    /// Same base-URL semantics as the Codex CLI: `chatgpt_base_url` may point
    /// at a proxy. ChatGPT-style hosts get "/backend-api" appended when it's
    /// missing; bases that route through "/backend-api" use the wham path,
    /// anything else the public API path.
    static func usageURL(base: String) -> URL {
        var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = defaultBaseURL }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("https://chatgpt.com") || base.hasPrefix("https://chat.openai.com"),
           !base.contains("/backend-api") {
            base += "/backend-api"
        }
        let path = base.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        return URL(string: base + path) ?? URL(string: defaultBaseURL + "/wham/usage")!
    }

    /// Minimal top-level scan for `chatgpt_base_url = "..."` — stops at the
    /// first `[section]` header so a same-named key inside a profile table
    /// can't leak out. Not worth a TOML dependency for one key.
    static func parseChatGPTBaseURL(_ toml: String) -> String? {
        let pattern = /chatgpt_base_url\s*=\s*"([^"]+)"/
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            if let match = line.prefixMatch(of: pattern) {
                return String(match.1)
            }
        }
        return nil
    }

    // MARK: - Response parsing

    /// Windows are classified by *length*, not by primary/secondary position:
    /// historically primary was 5h and secondary weekly, but when OpenAI
    /// dropped the 5h limit the weekly window moved into primary. Anything two
    /// days or longer is the weekly window.
    private static let weeklyMinSeconds = 2 * 24 * 3600

    static func parseUsageResponse(_ data: Data, now: Date = Date()) -> ProviderRateLimit? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = obj["rate_limit"] as? [String: Any]
        else { return nil }

        var fiveHour: RateLimitWindow?
        var sevenDay: RateLimitWindow?
        for slot in ["primary_window", "secondary_window"] {
            guard let dict = rateLimit[slot] as? [String: Any],
                  let parsed = parseWindow(dict, now: now) else { continue }
            if parsed.seconds >= weeklyMinSeconds {
                sevenDay = parsed.window
            } else {
                fiveHour = parsed.window
            }
        }

        var resetCredits: Int?
        if let rc = obj["rate_limit_reset_credits"] as? [String: Any],
           let count = rc["available_count"] as? Int, count > 0 {
            resetCredits = count
        }

        return ProviderRateLimit(
            provider: .codex,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            planLabel: formatPlanLabel(obj["plan_type"] as? String),
            status: (fiveHour == nil && sevenDay == nil) ? .noData : .ok,
            fetchedAt: now,
            dataAsOf: now,
            // The endpoint reports enforced windows exhaustively, so a missing
            // 5h window means the limit isn't currently enforced — a fact the
            // JSONL scan can never assert (there it just means "idle > 5h").
            fiveHourNotEnforced: fiveHour == nil,
            resetCreditsCount: resetCredits
        )
    }

    private struct ParsedWindow {
        var window: RateLimitWindow
        var seconds: Int
    }

    private static func parseWindow(_ dict: [String: Any], now: Date) -> ParsedWindow? {
        guard let used = dict["used_percent"] as? Double,
              let seconds = dict["limit_window_seconds"] as? Int else { return nil }

        var resetsAt: Date?
        if let epoch = dict["reset_at"] as? Double, epoch > 0 {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let after = dict["reset_after_seconds"] as? Double, after >= 0 {
            resetsAt = now.addingTimeInterval(after)
        }

        return ParsedWindow(
            window: RateLimitWindow(
                utilization: used,
                resetsAt: resetsAt,
                windowDuration: TimeInterval(seconds)
            ),
            seconds: seconds
        )
    }

    /// Same customer-facing capitalization as `CodexRateLimitReader`.
    private static func formatPlanLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    // MARK: - Snapshot cache (~/.vibe-usage/codex-rate-limits.json)

    /// The last successful live snapshot, persisted so the next popover open
    /// (including after an app relaunch) paints instantly from data that is at
    /// most as old as the previous refresh. This is what keeps the session-JSONL
    /// scan off the happy path entirely: as an instant-paint source the JSONL
    /// is both slower (the sessions tree can be hundreds of MB) and staler
    /// (it only updates while Codex is running) than our own last fetch.
    ///
    /// Deliberately a minimal DTO rather than the raw response: the endpoint
    /// payload carries account email / user ids we have no reason to write to
    /// disk. Windows whose reset has passed are dropped on load (same
    /// provably-rolled-over reasoning as `CodexRateLimitReader.parseWindow`);
    /// the weekly window resets within 7 days, so a dead cache naturally
    /// filters down to nil without a separate age cap.
    private struct CachedSnapshot: Codable {
        struct Window: Codable {
            var utilization: Double
            var resetsAt: Date?
            var windowDuration: TimeInterval?
        }

        var fetchedAt: Date
        var fiveHour: Window?
        var sevenDay: Window?
        var planLabel: String?
        var fiveHourNotEnforced: Bool
        var resetCreditsCount: Int?
    }

    static var cacheFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe-usage")
            .appendingPathComponent("codex-rate-limits.json")
    }

    /// Best-effort: a failed write just means the next cold open falls back to
    /// the network wait (spinner), never an error state.
    static func cache(_ snapshot: ProviderRateLimit, to url: URL = cacheFileURL) {
        guard snapshot.status == .ok else { return }
        func window(_ w: RateLimitWindow?) -> CachedSnapshot.Window? {
            w.map { .init(utilization: $0.utilization, resetsAt: $0.resetsAt, windowDuration: $0.windowDuration) }
        }
        let cached = CachedSnapshot(
            fetchedAt: snapshot.dataAsOf ?? Date(),
            fiveHour: window(snapshot.fiveHour),
            sevenDay: window(snapshot.sevenDay),
            planLabel: snapshot.planLabel,
            fiveHourNotEnforced: snapshot.fiveHourNotEnforced,
            resetCreditsCount: snapshot.resetCreditsCount
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cached) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// nil when there is no cache or every cached window has already reset —
    /// painting a provably rolled-over percentage would be confidently wrong.
    static func cachedSnapshot(from url: URL = cacheFileURL, now: Date = Date()) -> ProviderRateLimit? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode(CachedSnapshot.self, from: data) else { return nil }

        func liveWindow(_ w: CachedSnapshot.Window?) -> RateLimitWindow? {
            guard let w else { return nil }
            if let resetsAt = w.resetsAt, resetsAt <= now { return nil }
            return RateLimitWindow(
                utilization: w.utilization,
                resetsAt: w.resetsAt,
                windowDuration: w.windowDuration
            )
        }

        let fiveHour = liveWindow(cached.fiveHour)
        let sevenDay = liveWindow(cached.sevenDay)
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return ProviderRateLimit(
            provider: .codex,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            planLabel: cached.planLabel,
            status: .ok,
            fetchedAt: now,
            dataAsOf: cached.fetchedAt,
            // Only honor the cached "not enforced" assertion when the 5h slot
            // was empty at fetch time. A 5h window dropped just now for being
            // expired says nothing about enforcement — that placeholder should
            // read as "no data", and the live result corrects it in ~1s anyway.
            fiveHourNotEnforced: cached.fiveHour == nil && cached.fiveHourNotEnforced,
            resetCreditsCount: cached.resetCreditsCount
        )
    }
}
