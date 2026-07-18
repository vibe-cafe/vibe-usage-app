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

    @Test
    func readsSessionsFromCustomCodexHome() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }

        try fixture.writeRollout(
            named: "rollout-custom-home.jsonl",
            eventTimestamp: "2026-07-10T03:45:00Z",
            primaryUsed: 73,
            modifiedAt: try #require(parseFixtureDate("2026-07-10T03:46:00Z"))
        )

        let snapshot = CodexRateLimitReader.read(
            codexHome: fixture.root,
            now: try #require(parseFixtureDate("2026-07-10T04:00:00Z"))
        )

        #expect(snapshot.status == .ok)
        #expect(snapshot.fiveHour?.utilization == 73)
    }
}

private struct SessionFixture {
    let root: URL
    let sessionsDir: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRateLimitReaderTests-\(UUID().uuidString)")
        sessionsDir = root.appendingPathComponent("sessions/2026/07/10", isDirectory: true)
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
