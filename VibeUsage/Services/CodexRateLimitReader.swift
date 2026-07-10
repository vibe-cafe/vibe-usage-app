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

    /// Find the newest rate-limit event globally, not merely the event in the
    /// most recently-created rollout file. Codex Desktop can keep an older main
    /// session active after creating a newer guardian/sub-agent rollout, so a
    /// filename-first walk can pin the UI to the guardian's older snapshot.
    ///
    /// Files are ordered by modification time for efficiency. Once the next
    /// file's mtime is no newer than the best event timestamp, it cannot contain
    /// a later append and the remaining files can be skipped safely.
    private static func scanForLatest(in sessionsDir: URL, now: Date) -> Snapshot? {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [RolloutFile] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl",
                  file.lastPathComponent.hasPrefix("rollout-")
            else { continue }

            let values = try? file.resourceValues(forKeys: Set(resourceKeys))
            guard values?.isRegularFile != false else { continue }
            files.append(.init(url: file, modifiedAt: values?.contentModificationDate))
        }

        // Missing mtimes are scanned first so the optimization can never hide
        // a valid snapshot merely because metadata lookup failed.
        files.sort {
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
        for file in files {
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
