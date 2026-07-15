import Foundation

/// Fetches Codex usage + rate-limit-reset credits from ChatGPT's backend using
/// the user's *own* locally-stored OAuth token.
///
/// This is the one piece of the rate-limit feature that isn't a pure local-file
/// read: the "reset credits" count (how many manual usage-window resets the
/// account has banked) lives only server-side — no local file carries it. The
/// same endpoint also returns live window utilization, which is fresher and
/// more accurate than walking Codex's session JSONL (that walk can surface
/// stale/expired windows), so we prefer it as the primary source and fall back
/// to `CodexRateLimitReader` when the network/token isn't available.
///
/// Endpoint & shape are from Codex's own open-source backend client
/// (`codex-rs/backend-client`): the official CLI/app-server hits the exact same
/// `GET /backend-api/wham/usage`. We only ever GET — we never touch the
/// `.../consume` POST, which would actually spend a reset credit.
///
/// Privacy: the access token is read from `~/.codex/auth.json`, used only to
/// authenticate this request to `chatgpt.com`, and never logged, persisted, or
/// forwarded to the Vibe Usage backend.
enum CodexUsageAPIReader {

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let requestTimeout: TimeInterval = 10

    /// Returns a fully-populated snapshot on success, or nil when the API can't
    /// be used (no token, expired token → 401, offline, timeout, unexpected
    /// shape). A nil return is the caller's cue to fall back to the local
    /// session-file reader.
    static func fetch(now: Date = Date()) async -> ProviderRateLimit? {
        guard let auth = CodexAuth.load() else {
            debugLog("[rate-limit] codex API: no auth.json / access token — skipping API path")
            return nil
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Sent only when present; the server accepts the request with or without it.
        if let accountId = auth.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            debugLog("[rate-limit] codex API /wham/usage -> HTTP \(http.statusCode)")
            guard http.statusCode == 200 else {
                // 401 = token expired (Codex refreshes auth.json on its own next
                // run); anything else = transient. Either way, fall back locally.
                return nil
            }
            let decoder = JSONDecoder()
            // The payload is snake_case at every level; a global strategy keeps
            // nested structs in sync (a hand-written top-level CodingKeys would
            // silently leave nested fields nil — they're all Optional).
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let payload = try? decoder.decode(WhamUsageResponse.self, from: data) else {
                debugLog("[rate-limit] codex API: response shape changed — falling back")
                return nil
            }
            return payload.toSnapshot(now: now)
        } catch {
            debugLog("[rate-limit] codex API request failed: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - auth.json

/// The minimal slice of `~/.codex/auth.json` we need. Respects `CODEX_HOME`.
private struct CodexAuth {
    let accessToken: String
    let accountId: String?

    static func load() -> CodexAuth? {
        let base: URL
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            base = URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        let url = base.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else { return nil }
        return CodexAuth(accessToken: token, accountId: tokens["account_id"] as? String)
    }
}

// MARK: - Response shape

/// Mirrors the subset of `RateLimitStatusWithResetCredits` we consume
/// (`codex-rs/backend-client/src/types.rs`). Every field is optional so a
/// server-side rename degrades to a partial/failed parse rather than a crash.
private struct WhamUsageResponse: Decodable {
    let planType: String?
    let rateLimit: RateLimitObj?
    let rateLimitResetCredits: ResetCredits?

    struct RateLimitObj: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }

    struct Window: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Double?
        let resetAt: Double?
        let resetAfterSeconds: Double?
    }

    struct ResetCredits: Decodable {
        let availableCount: Int?
    }

    func toSnapshot(now: Date) -> ProviderRateLimit? {
        // `primary`/`secondary` have no fixed meaning — classify each by its
        // `limit_window_seconds` (300min → 5h, 10080min → 7d), mirroring the
        // local reader. Whichever slot carries the 5h window becomes `fiveHour`.
        var five: RateLimitWindow?
        var seven: RateLimitWindow?
        for slot in [rateLimit?.primaryWindow, rateLimit?.secondaryWindow] {
            guard let parsed = classify(slot, now: now) else { continue }
            switch parsed.minutes {
            case 300:   five = parsed.window
            case 10080: seven = parsed.window
            default:    continue
            }
        }

        // If neither window has live data, there's nothing to render — signal a
        // miss so the caller can fall back to the local session-file reader
        // (which might still have a recent snapshot).
        guard five != nil || seven != nil else { return nil }

        return ProviderRateLimit(
            provider: .codex,
            fiveHour: five,
            sevenDay: seven,
            planLabel: formatPlanLabel(planType),
            resetCredits: rateLimitResetCredits?.availableCount,
            status: .ok,
            fetchedAt: now
        )
    }

    /// Parse one API window into a `RateLimitWindow` plus its length in minutes
    /// (so the caller can bucket it). Drops a window whose reset is already in
    /// the past — same guard as the local reader against stale figures.
    private func classify(_ w: Window?, now: Date) -> (window: RateLimitWindow, minutes: Int)? {
        guard let w, let used = w.usedPercent, let seconds = w.limitWindowSeconds else { return nil }
        let minutes = Int((seconds / 60).rounded())

        var resetsAt: Date?
        if let epoch = w.resetAt, epoch > 0 {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let after = w.resetAfterSeconds, after >= 0 {
            resetsAt = now.addingTimeInterval(after)
        }
        if let resetsAt, resetsAt.timeIntervalSince(now) <= 0 { return nil }

        return (
            RateLimitWindow(
                utilization: used,
                resetsAt: resetsAt,
                windowDuration: TimeInterval(minutes * 60)
            ),
            minutes
        )
    }

    private func formatPlanLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
