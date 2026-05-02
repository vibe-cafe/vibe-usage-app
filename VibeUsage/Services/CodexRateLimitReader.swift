import Foundation

/// Reads Codex's local session JSONL to extract the most recent `rate_limits` event.
///
/// Codex writes rollouts to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Each line
/// is a JSON event; some have `payload.type == "token_count"` and carry a `rate_limits`
/// object with `primary` (5h) and `secondary` (7d) windows. We walk dates backwards
/// from today and return the first non-null `rate_limits` we find.
enum CodexRateLimitReader {

    static func read() -> ProviderRateLimit {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return .init(provider: .codex, status: .noData, fetchedAt: Date())
        }

        if let snapshot = scanForLatest(in: sessionsDir) {
            return ProviderRateLimit(
                provider: .codex,
                fiveHour: snapshot.fiveHour,
                sevenDay: snapshot.sevenDay,
                planLabel: snapshot.planLabel,
                status: .ok,
                fetchedAt: Date()
            )
        }
        return .init(provider: .codex, status: .noData, fetchedAt: Date())
    }

    // MARK: - File walk

    private struct Snapshot {
        var fiveHour: RateLimitWindow?
        var sevenDay: RateLimitWindow?
        var planLabel: String?
    }

    /// Walk year/month/day directories newest-first, scan each session file
    /// from end-to-start (most recent events first), return on first hit.
    private static func scanForLatest(in sessionsDir: URL) -> Snapshot? {
        let fm = FileManager.default
        guard let years = sortedSubdirs(of: sessionsDir, fm: fm) else { return nil }

        for year in years {
            guard let months = sortedSubdirs(of: year, fm: fm) else { continue }
            for month in months {
                guard let days = sortedSubdirs(of: month, fm: fm) else { continue }
                for day in days {
                    guard let files = try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil) else { continue }
                    let jsonl = files
                        .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
                        .sorted { $0.lastPathComponent > $1.lastPathComponent }
                    for file in jsonl {
                        if let snapshot = scan(file: file) {
                            return snapshot
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func sortedSubdirs(of url: URL, fm: FileManager) -> [URL]? {
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Parse one rollout JSONL file, return the most recent `rate_limits` block
    /// (if any). We read the whole file then iterate lines in reverse — Codex
    /// writes monotonically and the latest event has the freshest data.
    private static func scan(file: URL) -> Snapshot? {
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
            var snapshot = Snapshot()
            snapshot.planLabel = formatPlanLabel(rateLimits["plan_type"] as? String)
            for slot in ["primary", "secondary"] {
                guard let win = parseWindow(rateLimits[slot]) else { continue }
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

    /// Codex emits plan_type lowercase ("free", "plus", "pro", "business").
    /// Render the customer-facing capitalized form.
    private static func formatPlanLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private struct ParsedWindow {
        var window: RateLimitWindow
        var windowMinutes: Int
    }

    private static func parseWindow(_ raw: Any?) -> ParsedWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let usedPercent = dict["used_percent"] as? Double,
              let windowMinutes = dict["window_minutes"] as? Int else { return nil }

        var resetsAt: Date?
        if let epoch = dict["resets_at"] as? Double, epoch > 0 {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let secs = dict["resets_in_seconds"] as? Double, secs >= 0 {
            resetsAt = Date().addingTimeInterval(secs)
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
