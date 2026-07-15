import Foundation
import Testing
@testable import VibeUsage

struct CodexRateLimitReaderTests {
    @Test
    func choosesLatestEventAcrossOverlappingMainAndGuardianRollouts() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }

        // The guardian starts later, so the previous filename-based walk chose
        // its 81% snapshot even though the older main rollout kept writing.
        try fixture.writeRollout(
            named: "rollout-2026-07-10T11-39-40-guardian.jsonl",
            eventTimestamp: "2026-07-10T03:39:47.068Z",
            primaryUsed: 81,
            modifiedAt: try #require(parseFixtureDate("2026-07-10T03:39:48Z"))
        )
        try fixture.writeRollout(
            named: "rollout-2026-07-10T11-38-54-main.jsonl",
            eventTimestamp: "2026-07-10T03:44:06.347Z",
            primaryUsed: 85,
            modifiedAt: try #require(parseFixtureDate("2026-07-10T03:44:07Z"))
        )

        let snapshot = CodexRateLimitReader.read(
            sessionsDir: fixture.sessionsDir,
            now: try #require(parseFixtureDate("2026-07-10T04:00:00Z"))
        )

        #expect(snapshot.status == .ok)
        #expect(snapshot.fiveHour?.utilization == 85)
        #expect(snapshot.sevenDay?.utilization == 13)
        #expect(snapshot.planLabel == "Prolite")
    }

    @Test
    func comparesEventTimestampsWhenNewestModifiedFileHasOlderRateSnapshot() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }

        try fixture.writeRollout(
            named: "rollout-newer-mtime.jsonl",
            eventTimestamp: "2026-07-10T03:40:00Z",
            primaryUsed: 81,
            modifiedAt: try #require(parseFixtureDate("2026-07-10T03:50:00Z"))
        )
        try fixture.writeRollout(
            named: "rollout-newer-event.jsonl",
            eventTimestamp: "2026-07-10T03:45:00Z",
            primaryUsed: 84,
            modifiedAt: try #require(parseFixtureDate("2026-07-10T03:49:00Z"))
        )

        let snapshot = CodexRateLimitReader.read(
            sessionsDir: fixture.sessionsDir,
            now: try #require(parseFixtureDate("2026-07-10T04:00:00Z"))
        )

        #expect(snapshot.fiveHour?.utilization == 84)
    }

    /// Production `sessionsDir` is the top-level `~/.codex/sessions` folder,
    /// with rollouts nested under `yyyy/MM/dd`. This exercises the bounded
    /// fast path directly (as opposed to the other tests, which hand a leaf
    /// day-directory straight to `read` and exercise the full-scan fallback).
    @Test
    func findsRolloutInTodaysDateFolderViaFastPath() throws {
        let now = try #require(parseFixtureDate("2026-07-10T04:00:00Z"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRateLimitReaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try DatedRollout.write(
            under: root,
            day: now,
            named: "rollout-today.jsonl",
            eventTimestamp: "2026-07-10T03:44:06Z",
            primaryUsed: 42,
            modifiedAt: now
        )

        let snapshot = CodexRateLimitReader.read(sessionsDir: root, now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.fiveHour?.utilization == 42)
    }

    /// A rollout outside the lookback window can never carry a live window
    /// (its 7-day slot would already be expired), so the bounded fast path
    /// must not fall back to scanning it just because today's folder happens
    /// to be empty.
    @Test
    func ignoresRolloutsOlderThanTheLookbackWindow() throws {
        let now = try #require(parseFixtureDate("2026-07-10T04:00:00Z"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRateLimitReaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // Today's folder exists (so the fast path engages) but is empty.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(DatedRollout.dayPath(for: now)),
            withIntermediateDirectories: true
        )

        let staleDay = try #require(Calendar.current.date(byAdding: .day, value: -15, to: now))
        try DatedRollout.write(
            under: root,
            day: staleDay,
            named: "rollout-stale.jsonl",
            eventTimestamp: "2026-06-25T03:44:06Z",
            primaryUsed: 77,
            modifiedAt: staleDay
        )

        let snapshot = CodexRateLimitReader.read(sessionsDir: root, now: now)

        #expect(snapshot.status == .noData)
    }
}

private enum DatedRollout {
    static func dayPath(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.calendar = Calendar.current
        formatter.timeZone = .current
        return formatter.string(from: day)
    }

    static func write(
        under root: URL,
        day: Date,
        named name: String,
        eventTimestamp: String,
        primaryUsed: Double,
        modifiedAt: Date
    ) throws {
        let dayDir = root.appendingPathComponent(dayPath(for: day), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let event: [String: Any] = [
            "timestamp": eventTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": NSNull(),
                "rate_limits": [
                    "plan_type": "prolite",
                    "primary": [
                        "used_percent": primaryUsed,
                        "window_minutes": 300,
                        "resets_at": 4_102_444_800
                    ],
                    "secondary": [
                        "used_percent": 13.0,
                        "window_minutes": 10_080,
                        "resets_at": 4_102_444_800
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let file = dayDir.appendingPathComponent(name)
        try (data + Data([0x0A])).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
    }
}

private struct SessionFixture {
    let root: URL
    let sessionsDir: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRateLimitReaderTests-\(UUID().uuidString)")
        sessionsDir = root.appendingPathComponent("2026/07/10", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    func writeRollout(
        named name: String,
        eventTimestamp: String,
        primaryUsed: Double,
        modifiedAt: Date
    ) throws {
        let event: [String: Any] = [
            "timestamp": eventTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": NSNull(),
                "rate_limits": [
                    "plan_type": "prolite",
                    "primary": [
                        "used_percent": primaryUsed,
                        "window_minutes": 300,
                        "resets_at": 4_102_444_800
                    ],
                    "secondary": [
                        "used_percent": 13.0,
                        "window_minutes": 10_080,
                        "resets_at": 4_102_444_800
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let file = sessionsDir.appendingPathComponent(name)
        try (data + Data([0x0A])).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func parseFixtureDate(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: raw)
}
