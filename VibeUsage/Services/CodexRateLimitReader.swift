import Foundation

/// Reads Codex's local session JSONL to extract the most recent `rate_limits` event.
///
/// Codex writes rollouts to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Each line
/// is a JSON event; some have `payload.type == "token_count"` and carry a `rate_limits`
/// object with `primary` (5h) and `secondary` (7d) windows. Multiple main/guardian
/// rollouts may be active concurrently, so we compare their event timestamps and
/// return the globally newest non-null `rate_limits` block.
enum CodexRateLimitReader {

    static func read() -> ProviderRateLimit {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")

        return read(sessionsDir: sessionsDir)
    }

    /// Internal entry point used by tests with an isolated sessions directory.
    static func read(sessionsDir: URL, now: Date = Date()) -> ProviderRateLimit {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return .init(provider: .codex, status: .noData, fetchedAt: now)
        }

        if let snapshot = scanForLatest(in: sessionsDir, now: now) {
            // `parseWindow` already discarded any slot whose `resets_at` is in
            // the past — that window has provably rolled, and the snapshot's
            // `used_percent` is from the *previous* window, not the current
            // one. If BOTH slots were dropped (snapshot is fully expired)
            // there's no live data to report; collapse the card via .noData
            // rather than render confidently-wrong percentages. (When only one
            // slot is stale we still show the fresh one — 5h and 7d windows
            // expire independently.)
            if snapshot.fiveHour == nil && snapshot.sevenDay == nil {
                debugLog("[rate-limit] codex snapshot fully expired (no live windows) — reporting .noData")
                return .init(provider: .codex, status: .noData, fetchedAt: now)
            }
            return ProviderRateLimit(
                provider: .codex,
                fiveHour: snapshot.fiveHour,
                sevenDay: snapshot.sevenDay,
                planLabel: snapshot.planLabel,
                status: .ok,
                fetchedAt: now
            )
        }
        return .init(provider: .codex, status: .noData, fetchedAt: now)
    }

    // MARK: - File walk

    private struct Snapshot {
        var fiveHour: RateLimitWindow?
        var sevenDay: RateLimitWindow?
        var planLabel: String?
        var recordedAt: Date
    }

    private struct RolloutFile {
        var url: URL
        var modifiedAt: Date?
    }

    /// How many calendar days back to look for rollout files. A `rate_limits`
    /// event older than the 7-day window is provably expired — `parseWindow`
    /// already discards any slot whose `resets_at` has passed — so nothing
    /// beyond that horizon can ever contribute a *live* window. The extra two
    /// days absorb a session that straddles a day boundary (its rollout file
    /// lives in the day it was *created*, but keeps getting appended to) and
    /// any local clock/timezone drift between when Codex wrote the folder and
    /// when we compute "today" here.
    private static let lookbackDays = 9

    /// Find the newest rate-limit event globally, not merely the event in the
    /// most recently-created rollout file. Codex Desktop can keep an older main
    /// session active after creating a newer guardian/sub-agent rollout, so a
    /// filename-first walk can pin the UI to the guardian's older snapshot.
    ///
    /// Codex lays sessions out as `sessions/yyyy/MM/dd/rollout-*.jsonl`, so the
    /// fast path only touches the last `lookbackDays` day-folders instead of
    /// walking a user's entire multi-year session history on every refresh —
    /// that full walk was the main source of a sluggish first popover-open for
    /// long-time users. If `sessionsDir` doesn't follow that layout (test
    /// fixtures hand us a leaf directory directly, and a future Codex version
    /// might restructure), fall back to the old full recursive walk so we
    /// never silently miss data.
    private static func scanForLatest(in sessionsDir: URL, now: Date) -> Snapshot? {
        let dayDirs = recentDayDirectories(under: sessionsDir, now: now)
        if !dayDirs.isEmpty {
            return scan(files: dayDirs.flatMap(rolloutFiles(in:)), now: now)
        }
        return scan(files: allRolloutFiles(under: sessionsDir), now: now)
    }

    /// Existing `sessionsDir/yyyy/MM/dd` directories for the last
    /// `lookbackDays` calendar days, newest-day-first. Uses the device's local
    /// calendar/timezone, matching how Codex (running on the same machine)
    /// buckets its own session folders.
    private static func recentDayDirectories(under sessionsDir: URL, now: Date) -> [URL] {
        let calendar = Calendar.current
        var dirs: [URL] = []
        for offset in 0..<lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let url = sessionsDir.appendingPathComponent(dayPathFormatter.string(from: day))
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                dirs.append(url)
            }
        }
        return dirs
    }

    private static let dayPathFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        f.calendar = Calendar.current
        f.timeZone = .current
        return f
    }()

    /// Rollout files directly inside one `yyyy/MM/dd` leaf directory — Codex
    /// never nests further than that, so a shallow listing suffices (no need
    /// to stat every file in the tree, unlike the recursive fallback).
    private static func rolloutFiles(in dayDir: URL) -> [RolloutFile] {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dayDir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { file -> RolloutFile? in
            guard file.pathExtension == "jsonl", file.lastPathComponent.hasPrefix("rollout-") else { return nil }
            let values = try? file.resourceValues(forKeys: Set(resourceKeys))
            guard values?.isRegularFile != false else { return nil }
            return RolloutFile(url: file, modifiedAt: values?.contentModificationDate)
        }
    }

    /// Full recursive walk of `sessionsDir` — only reached when it doesn't
    /// follow the `yyyy/MM/dd` layout the fast path expects.
    private static func allRolloutFiles(under sessionsDir: URL) -> [RolloutFile] {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [RolloutFile] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl",
                  file.lastPathComponent.hasPrefix("rollout-")
            else { continue }

            let values = try? file.resourceValues(forKeys: Set(resourceKeys))
            guard values?.isRegularFile != false else { continue }
            files.append(.init(url: file, modifiedAt: values?.contentModificationDate))
        }
        return files
    }

    /// Sort newest-first and scan until a confirmed latest snapshot is found.
    /// Files are monotonic writers, so once the next candidate's mtime is no
    /// newer than the best event timestamp seen so far, it cannot contain a
    /// later append and the remaining files can be skipped safely.
    private static func scan(files: [RolloutFile], now: Date) -> Snapshot? {
        // Missing mtimes are scanned first so the optimization can never hide
        // a valid snapshot merely because metadata lookup failed.
        let sorted = files.sorted {
            switch ($0.modifiedAt, $1.modifiedAt) {
            case let (lhs?, rhs?):
                if lhs == rhs { return $0.url.path > $1.url.path }
                return lhs > rhs
            case (nil, nil):
                return $0.url.path > $1.url.path
            case (nil, _):
                return true
            case (_, nil):
                return false
            }
        }

        var latest: Snapshot?
        for file in sorted {
            if let latest,
               let modifiedAt = file.modifiedAt,
               modifiedAt <= latest.recordedAt {
                break
            }

            guard let snapshot = scan(
                file: file.url,
                fallbackTimestamp: file.modifiedAt ?? .distantPast,
                now: now
            ) else { continue }

            if let current = latest {
                if snapshot.recordedAt > current.recordedAt {
                    latest = snapshot
                }
            } else {
                latest = snapshot
            }
        }
        return latest
    }

    /// Parse one rollout JSONL file, return the most recent `rate_limits` block
    /// (if any). We read the whole file then iterate lines in reverse — Codex
    /// writes monotonically and the latest event has the freshest data.
    private static func scan(file: URL, fallbackTimestamp: Date, now: Date) -> Snapshot? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any]
            else { continue }

            // The "primary" / "secondary" slots don't have fixed semantics — `window_minutes`
            // identifies which subscription window each one represents. Plan tiers vary:
            // free plans only carry the 7d window in primary; Plus/Pro return both.
            var snapshot = Snapshot(
                recordedAt: parseTimestamp(obj["timestamp"]) ?? fallbackTimestamp
            )
            snapshot.planLabel = formatPlanLabel(rateLimits["plan_type"] as? String)
            for slot in ["primary", "secondary"] {
                guard let win = parseWindow(rateLimits[slot], now: now) else { continue }
                switch win.windowMinutes {
                case 300:    snapshot.fiveHour = win.window
                case 10080:  snapshot.sevenDay = win.window
                default:     continue
                }
            }
            return snapshot
        }
        return nil
    }

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        guard let raw = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// Codex emits plan_type lowercase ("free", "plus", "pro", "prolite", "business").
    /// Render the customer-facing capitalized form.
    private static func formatPlanLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private struct ParsedWindow {
        var window: RateLimitWindow
        var windowMinutes: Int
    }

    private static func parseWindow(_ raw: Any?, now: Date) -> ParsedWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let usedPercent = dict["used_percent"] as? Double,
              let windowMinutes = dict["window_minutes"] as? Int else { return nil }

        var resetsAt: Date?
        if let epoch = dict["resets_at"] as? Double, epoch > 0 {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let secs = dict["resets_in_seconds"] as? Double, secs >= 0 {
            resetsAt = now.addingTimeInterval(secs)
        }

        // Reject a window whose `resets_at` is already in the past: Codex's
        // rolling-window semantics guarantee that the window has rolled over
        // and `used_percent` is from the *previous* window — showing it as
        // current was the source of "数据不对" feedback (e.g. an 8% reading
        // hanging around 12 days after that window expired). The card layer
        // collapses gracefully when no live slots remain (see `read()`).
        //
        // Without a `resets_at` at all we keep the window (utilization is
        // probably still meaningful; we just can't render the time bar) —
        // that matches the Claude reader's tolerance for missing timestamps.
        if let resetsAt, resetsAt.timeIntervalSince(now) <= 0 {
            debugLog("[rate-limit] codex \(windowMinutes)m window expired \(Int(-resetsAt.timeIntervalSince(now)))s ago — dropping stale slot")
            return nil
        }

        return ParsedWindow(
            window: RateLimitWindow(
                utilization: usedPercent,
                resetsAt: resetsAt,
                windowDuration: TimeInterval(windowMinutes * 60)
            ),
            windowMinutes: windowMinutes
        )
    }
}
