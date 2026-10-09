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

    // MARK: - Tail walk

    /// The walk reads a rollout backwards in fixed chunks; every case below is
    /// a way the newest `rate_limits` event can sit across a chunk boundary.
    /// They pin the equivalence with the whole-file read the walk replaced.

    @Test
    func findsEventFarBehindTheTailChunk() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }

        let chunk = CodexRateLimitReader.scanChunkBytes
        let filler = fillerLines(count: 4 * chunk / fillerLineBytes)

        try fixture.writeRawRollout(
            named: "rollout-deep-match.jsonl",
            lines: [try fixture.eventLine(eventTimestamp: "2026-07-10T03:45:00Z", primaryUsed: 71)]
                + filler,
            modifiedAt: try #require(parseFixtureDate("2026-07-10T03:46:00Z"))
        )

        let snapshot = CodexRateLimitReader.read(
            sessionsDir: fixture.sessionsDir,
            now: try #require(parseFixtureDate("2026-07-10T04:00:00Z"))
        )

        #expect(snapshot.fiveHour?.utilization == 71)
    }

    @Test
    func findsEventWhoseLineStraddlesAChunkBoundary() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }

        let chunk = CodexRateLimitReader.scanChunkBytes
        let event = try fixture.eventLine(eventTimestamp: "2026-07-10T03:45:00Z", primaryUsed: 77)
        // Filler after the event puts the first chunk's boundary inside the
        // event's own line, so its head and tail arrive in different reads.
        let tail = [fillerLine(byteCount: chunk - event.utf8.count + 10)]

        try fixture.writeRawRollout(
            named: "rollout-straddling-match.jsonl",
            lines: [fillerLine(byteCount: 200), event] + tail,
            modifiedAt: try #require(parseFixtureDate("2026-07-10T03:46:00Z"))
        )

        let snapshot = CodexRateLimitReader.read(
            sessionsDir: fixture.sessionsDir,
            now: try #require(parseFixtureDate("2026-07-10T04:00:00Z"))
        )

        #expect(snapshot.fiveHour?.utilization == 77)
    }

    @Test
    func skipsALineLongerThanAChunkThatSitsNewerThanTheMatch() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }

        let chunk = CodexRateLimitReader.scanChunkBytes
        let giantToolOutput = fillerLine(byteCount: 3 * chunk / 2)
        // No trailing newline: Codex appends while it writes, so the tail can
        // be one line longer than a chunk that nothing has closed yet.
        try fixture.writeRawRollout(
            named: "rollout-giant-line.jsonl",
            lines: [
                try fixture.eventLine(eventTimestamp: "2026-07-10T03:45:00Z", primaryUsed: 69),
                giantToolOutput
            ],
            modifiedAt: try #require(parseFixtureDate("2026-07-10T03:46:00Z")),
            trailingNewline: false
        )

        let snapshot = CodexRateLimitReader.read(
            sessionsDir: fixture.sessionsDir,
            now: try #require(parseFixtureDate("2026-07-10T04:00:00Z"))
        )

        #expect(snapshot.fiveHour?.utilization == 69)
    }

    @Test
    func returnsTheNewestEventWhenAFileHoldsSeveral() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }

        try fixture.writeRawRollout(
            named: "rollout-several-events.jsonl",
            lines: [
                try fixture.eventLine(eventTimestamp: "2026-07-10T03:40:00Z", primaryUsed: 64),
                fillerLine(byteCount: 400),
                try fixture.eventLine(eventTimestamp: "2026-07-10T03:45:00Z", primaryUsed: 82)
            ],
            modifiedAt: try #require(parseFixtureDate("2026-07-10T03:46:00Z"))
        )

        let snapshot = CodexRateLimitReader.read(
            sessionsDir: fixture.sessionsDir,
            now: try #require(parseFixtureDate("2026-07-10T04:00:00Z"))
        )

        #expect(snapshot.fiveHour?.utilization == 82)
    }

    @Test
    func ignoresANewerLineThatMentionsRateLimitsWithoutBeingATokenCount() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }

        // The byte pre-filter accepts this line, so only the `payload.type`
        // check can reject it — a wrong snapshot here would be invisible.
        let decoy = #"{"timestamp":"2026-07-10T03:46:00Z","type":"event_msg","payload":{"type":"tool_output","text":"\"rate_limits\""}}"#
        try fixture.writeRawRollout(
            named: "rollout-decoy.jsonl",
            lines: [
                try fixture.eventLine(eventTimestamp: "2026-07-10T03:45:00Z", primaryUsed: 66),
                decoy
            ],
            modifiedAt: try #require(parseFixtureDate("2026-07-10T03:47:00Z"))
        )

        let snapshot = CodexRateLimitReader.read(
            sessionsDir: fixture.sessionsDir,
            now: try #require(parseFixtureDate("2026-07-10T04:00:00Z"))
        )

        #expect(snapshot.fiveHour?.utilization == 66)
    }
}

private let fillerLineBytes = 160

/// A non-`token_count` event of a size the caller can steer, so a test can
/// place a line boundary where it wants one.
private func fillerLine(byteCount: Int) -> String {
    let text = String(repeating: "x", count: max(0, byteCount - 60))
    return #"{"timestamp":"2026-07-10T03:41:00Z","type":"event_msg","payload":{"type":"tool_output","text":"\#(text)"}}"#
}

private func fillerLines(count: Int) -> [String] {
    (0..<count).map { _ in fillerLine(byteCount: fillerLineBytes) }
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
        try writeRawRollout(
            named: name,
            lines: [try eventLine(eventTimestamp: eventTimestamp, primaryUsed: primaryUsed)],
            modifiedAt: modifiedAt
        )
    }

    /// One `token_count` rollout line, the shape Codex appends.
    func eventLine(eventTimestamp: String, primaryUsed: Double) throws -> String {
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
        return String(decoding: data, as: UTF8.self)
    }

    /// Write the rollout verbatim so a test can control where line boundaries
    /// fall relative to the reader's scan chunks.
    func writeRawRollout(
        named name: String,
        lines: [String],
        modifiedAt: Date,
        trailingNewline: Bool = true
    ) throws {
        var data = Data()
        for (index, line) in lines.enumerated() {
            data.append(contentsOf: line.utf8)
            if index < lines.count - 1 || trailingNewline {
                data.append(0x0A)
            }
        }
        let file = sessionsDir.appendingPathComponent(name)
        try data.write(to: file)
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
