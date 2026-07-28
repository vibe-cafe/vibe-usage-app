import Foundation
import Testing
@testable import VibeUsage

struct ClaudeUsageCacheTests {

    private let now = ISO8601DateFormatter().date(from: "2026-07-28T04:00:00Z")!

    private func write(_ object: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageCacheTests-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    // MARK: - Layer 1: ~/.claude.json

    /// Verbatim shape Claude Code writes after each successful usage fetch.
    private func configFile(
        fetchedAt: Date,
        cachedAccount: String = "acct-1",
        activeAccount: String = "acct-1",
        fiveHourResetsAt: String = "2026-07-28T05:20:00.014602+00:00"
    ) -> [String: Any] {
        [
            "oauthAccount": ["accountUuid": activeAccount],
            "cachedUsageUtilization": [
                "fetchedAtMs": fetchedAt.timeIntervalSince1970 * 1000,
                "accountUuid": cachedAccount,
                "utilization": [
                    "five_hour": ["utilization": 14, "resets_at": fiveHourResetsAt],
                    "seven_day": [
                        "utilization": 10,
                        "resets_at": "2026-08-01T20:00:00.014652+00:00",
                    ],
                    "seven_day_opus": NSNull(),
                ],
            ],
        ]
    }

    @Test
    func readsWindowsAndCarriesClaudesOwnFetchTime() throws {
        let fetchedAt = now.addingTimeInterval(-600)
        let url = try write(configFile(fetchedAt: fetchedAt))
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try #require(ClaudeUsageCache.configSnapshot(from: url, now: now))

        #expect(snapshot.provider == .claudeCode)
        #expect(snapshot.fiveHour?.utilization == 14)
        #expect(snapshot.sevenDay?.utilization == 10)
        // Age comes from Claude's fetch, not from our read — this is what makes
        // the card say 「数据截至 10 分钟前」 instead of claiming to be live.
        #expect(snapshot.dataAsOf == fetchedAt)
    }

    /// After an account switch Claude Code leaves the previous account's numbers
    /// in place until its next fetch. Showing those would be plainly wrong, and
    /// both values needed to detect it live in this one file.
    @Test
    func rejectsCacheLeftBehindByAnotherAccount() throws {
        let url = try write(
            configFile(fetchedAt: now, cachedAccount: "old", activeAccount: "new")
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ClaudeUsageCache.configSnapshot(from: url, now: now) == nil)
    }

    @Test
    func rejectsSnapshotsBeyondTheHardAgeBound() throws {
        let url = try write(configFile(fetchedAt: now.addingTimeInterval(-8 * 86_400)))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ClaudeUsageCache.configSnapshot(from: url, now: now) == nil)
    }

    @Test
    func expiredWindowKeepsPercentageButLosesItsDuration() throws {
        let url = try write(
            configFile(fetchedAt: now, fiveHourResetsAt: "2026-07-28T03:00:00Z")
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try #require(ClaudeUsageCache.configSnapshot(from: url, now: now))
        #expect(snapshot.fiveHour?.utilization == 14)
        #expect(snapshot.fiveHour?.windowDuration == nil)
    }

    @Test
    func missingCacheKeyYieldsNoSnapshot() throws {
        let url = try write(["oauthAccount": ["accountUuid": "acct-1"]])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ClaudeUsageCache.configSnapshot(from: url, now: now) == nil)
    }

    // MARK: - Layer 3: Claude Desktop's plan-usage-history.json

    @Test
    func readsLatestDesktopHistorySample() throws {
        let sampledAt = now.addingTimeInterval(-120)
        let url = try write([
            "version": 2,
            "samples": [
                ["t": now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000,
                 "org": "org-1", "u": ["fh": 4, "sd": 20]],
                ["t": sampledAt.timeIntervalSince1970 * 1000,
                 "org": "org-1", "u": ["fh": 9, "sd": 23]],
            ],
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try #require(ClaudeUsageCache.desktopHistorySnapshot(from: url, now: now))
        #expect(snapshot.fiveHour?.utilization == 9)
        #expect(snapshot.sevenDay?.utilization == 23)
        #expect(snapshot.dataAsOf == sampledAt)
        // The file carries no reset timestamps, so there is no time bar to draw.
        #expect(snapshot.fiveHour?.resetsAt == nil)
        #expect(snapshot.fiveHour?.windowDuration == nil)
    }

    /// Without a reset timestamp, staleness can only be bounded by window
    /// length: a 5h percentage sampled over 5 hours ago may belong to a window
    /// that has since rolled over.
    @Test
    func dropsFiveHourSampleOlderThanTheWindowItDescribes() throws {
        let url = try write([
            "version": 2,
            "samples": [[
                "t": now.addingTimeInterval(-6 * 3600).timeIntervalSince1970 * 1000,
                "org": "org-1",
                "u": ["fh": 9, "sd": 23],
            ]],
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try #require(ClaudeUsageCache.desktopHistorySnapshot(from: url, now: now))
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay?.utilization == 23)
    }

    /// Desktop still accepts its own v1 layout, which put the percentages flat
    /// on the sample instead of nesting them under `u`.
    @Test
    func readsLegacyVersionOneSampleLayout() throws {
        let url = try write([
            "version": 1,
            "samples": [[
                "t": now.timeIntervalSince1970 * 1000,
                "fh": 7,
                "sd": 21,
            ]],
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try #require(ClaudeUsageCache.desktopHistorySnapshot(from: url, now: now))
        #expect(snapshot.fiveHour?.utilization == 7)
        #expect(snapshot.sevenDay?.utilization == 21)
    }
}
