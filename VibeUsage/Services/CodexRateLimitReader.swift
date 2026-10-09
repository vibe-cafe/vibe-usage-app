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
        read(codexHome: CodexUsageAPI.codexHome)
    }

    /// Keep the offline fallback in the same Codex namespace as auth/config.
    /// This matters for users who launch the app with a custom `CODEX_HOME`.
    static func read(codexHome: URL, now: Date = Date()) -> ProviderRateLimit {
        read(sessionsDir: codexHome.appendingPathComponent("sessions"), now: now)
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
            // there's no live data to report; report `.noData` rather than
            // render confidently-wrong percentages. (When only one slot is
            // stale we still show the fresh one — 5h and 7d windows expire
            // independently.) A JSONL scan cannot say *why* nothing is left,
            // so the card keeps a neutral copy for it.
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
                fetchedAt: now,
                // The JSONL event timestamp: how old these numbers really are.
                // `.distantPast` fallbacks (mtime lookup failed) stay nil so the
                // card doesn't render a nonsense 「数据截至 55 年前」.
                dataAsOf: snapshot.recordedAt > .distantPast ? snapshot.recordedAt : nil
            )
        }
        return .init(provider: .codex, status: .noData, fetchedAt: now)
    }

    // MARK: - File walk

    /// Tail chunk for the backwards rollout walk. A rollout grows for as long
    /// as its Codex session lives; the biggest one on this machine is 469 MB,
    /// so it is read in bounded pieces instead of whole. Peak memory is one
    /// chunk plus the longest single line (tool output tops out around 9 MB in
    /// real rollouts) rather than 2× the file. Internal so tests can place a
    /// line boundary on a chunk edge.
    static let scanChunkBytes = 256 * 1024

    private static let newlineByte: UInt8 = 0x0A

    /// Pre-filter for `JSONSerialization`: every line that can produce a
    /// snapshot contains this key, and rejecting the rest by byte search keeps
    /// a chunk of tool output from being parsed.
    private static let rateLimitsKey = Data("\"rate_limits\"".utf8)

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
    /// (if any). Codex appends monotonically, so the newest event sits at the
    /// tail: we walk the file backwards in fixed chunks and stop at the first
    /// match. That is the same line the whole-file read returned — newest line
    /// first is preserved — but the file never has to exist in memory. Real
    /// rollouts reach hundreds of megabytes (a long session keeps appending),
    /// and `String(contentsOf:)` + `split` cost ~2× the file size *and* left
    /// the pages resident in the malloc arena until macOS reclaimed them under
    /// pressure, which is what inflated the app's footprint in Force Quit.
    private static func scan(file: URL, fallbackTimestamp: Date, now: Date) -> Snapshot? {
        // POSIX rather than FileHandle: `read(upToCount:)` allocates per call
        // and the process footprint tracks everything it read — a deep walk
        // over a 469 MB rollout cost ~950 MB that way. One reusable buffer
        // plus `pread` keeps the walk flat (~2 MB) at any file size.
        let descriptor = file.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        let size = lseek(descriptor, 0, SEEK_END)
        guard size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: scanChunkBytes)
        var offset = size
        // Head of the chunk just read: a line that continues into the older
        // bytes still unread. The next iteration completes it.
        var carry = Data()

        while offset > 0 {
            let count = Int(min(Int64(scanChunkBytes), offset))
            offset -= Int64(count)
            let read = buffer.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress, count, off_t(offset))
            }
            guard read == count else { return nil }

            var window = Data(buffer[0..<read])
            window.append(carry)

            // Everything before the first newline is only completed by the
            // older chunk, so it waits in `carry`; the rest is whole lines. A
            // single line longer than the chunk keeps accumulating instead.
            let searchable: Data
            if offset > 0, let firstBreak = window.firstIndex(of: newlineByte) {
                carry = window[window.startIndex..<firstBreak]
                searchable = window[firstBreak...]
            } else if offset > 0 {
                carry = window
                continue
            } else {
                carry = Data()
                searchable = window
            }

            let lines = searchable.split(separator: newlineByte, omittingEmptySubsequences: true)
            for line in lines.reversed() {
                // Cheap reject first: only a line carrying the key can yield a
                // snapshot, and most lines in a rollout are tool output.
                guard line.range(of: rateLimitsKey) != nil,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count",
                      let rateLimits = payload["rate_limits"] as? [String: Any]
                else { continue }

                return snapshot(
                    recordedAt: parseTimestamp(obj["timestamp"]) ?? fallbackTimestamp,
                    rateLimits: rateLimits,
                    now: now
                )
            }
        }
        return nil
    }

    /// Project one `rate_limits` block onto the windows the card renders.
    private static func snapshot(
        recordedAt: Date,
        rateLimits: [String: Any],
        now: Date
    ) -> Snapshot {
        // The "primary" / "secondary" slots don't have fixed semantics — `window_minutes`
        // identifies which subscription window each one represents. Plan tiers vary:
        // free plans only carry the 7d window in primary; Plus/Pro return both.
        var snapshot = Snapshot(recordedAt: recordedAt)
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
        // hanging around 12 days after that window expired). When no live
        // slots remain the card reports plain `.noData` — it cannot say why
        // (see `read()`).
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
