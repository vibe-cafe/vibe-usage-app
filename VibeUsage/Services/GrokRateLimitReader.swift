import Foundation

/// Offline Grok quota fallback: the latest `billing: fetched credits config`
/// event in `~/.grok/logs/unified.jsonl`.
///
/// The official CLI logs every successful credits fetch (the same payload the
/// live `/billing?format=credits` endpoint returns, plus `subscriptionTier`
/// already enriched from remote settings). The log only updates while Grok is
/// running, so this stays off the happy path — the coordinator paints the last
/// live cache first and only walks the log when the network fails.
enum GrokRateLimitReader {

    static func read() -> ProviderRateLimit {
        read(grokHome: GrokUsageAPI.grokHome)
    }

    static func read(grokHome: URL, now: Date = Date()) -> ProviderRateLimit {
        read(
            logFile: grokHome.appendingPathComponent("logs").appendingPathComponent("unified.jsonl"),
            now: now
        )
    }

    /// Internal entry point used by tests with an isolated log file.
    static func read(logFile: URL, now: Date = Date()) -> ProviderRateLimit {
        guard FileManager.default.fileExists(atPath: logFile.path) else {
            return .init(provider: .grok, status: .noData, fetchedAt: now)
        }
        guard let raw = readTail(of: logFile) else {
            return .init(provider: .grok, status: .noData, fetchedAt: now)
        }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["msg"] as? String) == "billing: fetched credits config",
                  let ctx = obj["ctx"] as? [String: Any],
                  var snapshot = GrokUsageAPI.parseCreditsObject(ctx, now: now)
            else { continue }

            let recordedAt = GrokUsageAPI.parseISO8601(obj["ts"] as? String)
            if snapshot.status != .ok {
                // Latest event is fully expired / empty — older weeks are the
                // previous window, not current quota. Collapse rather than
                // walking backwards.
                debugLog("[rate-limit] grok log snapshot fully expired — reporting .noData")
                return .init(provider: .grok, status: .noData, fetchedAt: now)
            }
            snapshot.fetchedAt = now
            snapshot.dataAsOf = recordedAt ?? snapshot.dataAsOf
            return snapshot
        }
        return .init(provider: .grok, status: .noData, fetchedAt: now)
    }

    /// Billing events are small; the log can be large. Reading the last 2 MB
    /// is enough for many recent fetches without walking hundreds of MB of
    /// unrelated shell output.
    private static let tailBytes = 2_000_000

    private static func readTail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size: UInt64
        do {
            size = try handle.seekToEnd()
        } catch {
            return nil
        }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd(),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }

        if start == 0 { return raw }
        guard let newline = raw.firstIndex(of: "\n") else { return raw }
        return String(raw[raw.index(after: newline)...])
    }
}
