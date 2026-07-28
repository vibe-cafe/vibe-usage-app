import Foundation

/// The two on-disk quota snapshots Claude's own clients leave behind. Both are
/// plain file reads — no auth, no network, no subprocess — so they can paint the
/// card the instant the popover opens while `ClaudeUsageProbe` does its ~2.5s
/// round trip in the background.
///
/// Neither is a substitute for the probe: each is only as fresh as the last time
/// some Claude client happened to fetch usage. They exist to remove the blank
/// card from the cold-open path, and to keep *something* on screen when the
/// probe cannot run (no binary, offline, logged out).
enum ClaudeUsageCache {

    // MARK: - Layer 1: ~/.claude.json (written by Claude Code itself)

    /// Claude Code persists every successful usage fetch to `cachedUsageUtilization`
    /// in its config file, in the endpoint's own shape — including `resets_at`,
    /// which the Desktop history file lacks. That makes this the better of the
    /// two caches: it can drive the reset countdown and the elapsed-time bar.
    ///
    /// Who keeps it fresh: any Claude Code session, including the ones Claude
    /// Desktop spawns for its Code panes, and our own probe. Notably *not* the
    /// Desktop app's Electron process, which polls a different endpoint
    /// (`/api/organizations/{org}/usage`) and only writes `plan-usage-history.json`.
    /// So on a Desktop-only machine this file goes stale while the user is idle
    /// and refreshes as soon as they actually run something — which is when the
    /// numbers matter.
    ///
    /// ```json
    /// { "fetchedAtMs": 1784216189978,
    ///   "accountUuid": "…",
    ///   "utilization": { "five_hour": { "utilization": 14, "resets_at": "…" }, … } }
    /// ```
    static func configSnapshot(
        from url: URL = configFileURL,
        now: Date = Date()
    ) -> ProviderRateLimit? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = ClaudeUsageProbe.number(cached["fetchedAtMs"]),
              let utilization = cached["utilization"] as? [String: Any]
        else { return nil }

        // Both the cache entry and the active login live in this one file, so
        // the account can be verified without touching credentials. After an
        // account switch Claude Code leaves the previous account's numbers in
        // place until its next fetch — showing those would be plainly wrong.
        if let cachedAccount = cached["accountUuid"] as? String,
           let activeAccount = (root["oauthAccount"] as? [String: Any])?["accountUuid"] as? String,
           cachedAccount != activeAccount {
            return nil
        }

        let fetchedAt = Date(timeIntervalSince1970: fetchedAtMs / 1000)
        let age = now.timeIntervalSince(fetchedAt)
        // A hard bound so a machine whose Claude install went unused for months
        // cannot flash ancient percentages. Individual windows are additionally
        // dropped below once their reset has passed.
        guard age >= 0, age <= maxCacheAge else { return nil }

        let fiveHour = window(utilization["five_hour"], duration: ClaudeUsageProbe.fiveHourDuration, now: now)
        let sevenDay = window(utilization["seven_day"], duration: ClaudeUsageProbe.sevenDayDuration, now: now)
        let opus = window(utilization["seven_day_opus"], duration: ClaudeUsageProbe.sevenDayDuration, now: now)
        let sonnet = window(utilization["seven_day_sonnet"], duration: ClaudeUsageProbe.sevenDayDuration, now: now)
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return ProviderRateLimit(
            provider: .claudeCode,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOpus: opus,
            sevenDaySonnet: sonnet,
            status: .ok,
            fetchedAt: now,
            // The numbers are as old as Claude's own fetch, not as old as our
            // read — this is what drives 「数据截至 N 分钟前」.
            dataAsOf: fetchedAt
        )
    }

    /// `~/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json` when the user has
    /// relocated their Claude profile (same rule Claude Code applies).
    static var configFileURL: URL {
        let base: URL
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            base = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
        }
        return base.appendingPathComponent(".claude.json")
    }

    private static let maxCacheAge: TimeInterval = 7 * 86_400

    /// Endpoint window shape, identical to the probe's. An already-reset window
    /// keeps its percentage but drops `windowDuration` so the elapsed-time bar
    /// cannot render a confidently wrong 100%.
    private static func window(_ raw: Any?, duration: TimeInterval, now: Date) -> RateLimitWindow? {
        guard let dict = raw as? [String: Any],
              let utilization = ClaudeUsageProbe.number(dict["utilization"])
        else { return nil }
        let resetsAt = (dict["resets_at"] as? String).flatMap(ClaudeUsageProbe.parseISO8601)
        let resetInFuture = (resetsAt.map { $0 > now }) ?? false
        return RateLimitWindow(
            utilization: utilization,
            resetsAt: resetsAt,
            windowDuration: resetInFuture ? duration : nil
        )
    }

    // MARK: - Layer 3: Claude Desktop's own usage history

    /// Claude Desktop samples its usage poll into `plan-usage-history.json`
    /// (30-day ring, appended at most every 4.5 minutes). Last-resort only, for
    /// two reasons found by reading the app bundle:
    ///
    /// 1. **No `resets_at`.** The schema is `{t, org, u:{fh, sd, …}}` — just
    ///    percentages. No reset countdown, no elapsed-time bar.
    /// 2. **The 5-minute poll that feeds it is gated on the user having turned
    ///    on Claude Desktop's own menu-bar usage indicator.** With that switch
    ///    off the file only gets the sample written at launch and then sits
    ///    still, so freshness cannot be assumed.
    ///
    /// Because there is no reset timestamp to check, staleness is bounded by
    /// window length instead: a 5h percentage sampled over 5 hours ago may
    /// belong to a window that has since rolled over, so it is dropped.
    static func desktopHistorySnapshot(
        from url: URL = desktopHistoryFileURL,
        now: Date = Date()
    ) -> ProviderRateLimit? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]],
              let latest = samples.last,
              let sampledAtMs = ClaudeUsageProbe.number(latest["t"])
        else { return nil }

        let sampledAt = Date(timeIntervalSince1970: sampledAtMs / 1000)
        let age = now.timeIntervalSince(sampledAt)
        guard age >= 0 else { return nil }

        // v2 nests percentages under `u` with short keys; v1 put `fh`/`sd` flat
        // on the sample. Both shapes are still accepted by Desktop, so both are
        // read here.
        let values = (latest["u"] as? [String: Any]) ?? latest

        func window(_ key: String, maxAge: TimeInterval) -> RateLimitWindow? {
            guard age <= maxAge, let percent = ClaudeUsageProbe.number(values[key]) else { return nil }
            return RateLimitWindow(utilization: percent)
        }

        let fiveHour = window("fh", maxAge: ClaudeUsageProbe.fiveHourDuration)
        let sevenDay = window("sd", maxAge: ClaudeUsageProbe.sevenDayDuration)
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return ProviderRateLimit(
            provider: .claudeCode,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOpus: window("so", maxAge: ClaudeUsageProbe.sevenDayDuration),
            sevenDaySonnet: window("sn", maxAge: ClaudeUsageProbe.sevenDayDuration),
            status: .ok,
            fetchedAt: now,
            dataAsOf: sampledAt
        )
    }

    static var desktopHistoryFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    // MARK: - Combined

    /// Best available on-disk snapshot: the config cache when it has usable
    /// windows, else Desktop's history. Ordered by information content — only
    /// the former carries reset times.
    static func bestSnapshot(now: Date = Date()) -> ProviderRateLimit? {
        configSnapshot(now: now) ?? desktopHistorySnapshot(now: now)
    }
}
