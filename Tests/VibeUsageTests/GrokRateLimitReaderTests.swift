import Foundation
import Testing
@testable import VibeUsage

struct GrokRateLimitReaderTests {

    @Test
    func readsLatestUnexpiredBillingEvent() throws {
        let fixture = try GrokLogFixture()
        defer { fixture.remove() }

        try fixture.append(
            ts: "2026-08-30T07:00:00.000Z",
            percent: 1,
            start: "2026-08-27T06:44:52Z",
            end: "2026-09-03T06:44:52Z",
            tier: "SuperGrok"
        )
        try fixture.append(
            ts: "2026-08-30T09:00:00.000Z",
            percent: 9,
            start: "2026-08-27T06:44:52Z",
            end: "2026-09-03T06:44:52Z",
            tier: "SuperGrok Plus"
        )

        let snapshot = GrokRateLimitReader.read(
            grokHome: fixture.root,
            now: try #require(GrokUsageAPI.parseISO8601("2026-08-30T10:00:00Z"))
        )

        #expect(snapshot.status == .ok)
        #expect(snapshot.sevenDay?.utilization == 9)
        #expect(snapshot.planLabel == "SuperGrok Plus")
        #expect(snapshot.dataAsOf == GrokUsageAPI.parseISO8601("2026-08-30T09:00:00.000Z"))
    }

    @Test
    func expiredLatestEventReportsNoDataInsteadOfOlderWeek() throws {
        let fixture = try GrokLogFixture()
        defer { fixture.remove() }

        try fixture.append(
            ts: "2026-08-23T21:44:17.000Z",
            percent: 40,
            start: "2026-08-20T06:44:52Z",
            end: "2026-08-27T06:44:52Z",
            tier: "SuperGrok Plus"
        )
        try fixture.append(
            ts: "2026-08-30T09:00:00.000Z",
            percent: 100,
            start: "2026-08-27T06:44:52Z",
            end: "2026-09-03T06:44:52Z",
            tier: "SuperGrok Plus"
        )

        let snapshot = GrokRateLimitReader.read(
            grokHome: fixture.root,
            now: try #require(GrokUsageAPI.parseISO8601("2026-09-04T00:00:00Z"))
        )

        #expect(snapshot.status == .noData)
        #expect(snapshot.sevenDay == nil)
    }

    @Test
    func missingLogFileIsNoData() throws {
        let fixture = try GrokLogFixture(createLog: false)
        defer { fixture.remove() }

        let snapshot = GrokRateLimitReader.read(grokHome: fixture.root)
        #expect(snapshot.status == .noData)
    }

    @Test
    func skipsUnrelatedLogLines() throws {
        let fixture = try GrokLogFixture()
        defer { fixture.remove() }

        try fixture.appendRaw(#"{ "ts": "2026-08-30T08:00:00Z", "msg": "session started" }"#)
        try fixture.append(
            ts: "2026-08-30T09:00:00.000Z",
            percent: 4,
            start: "2026-08-27T06:44:52Z",
            end: "2026-09-03T06:44:52Z",
            tier: "SuperGrok Plus"
        )

        let snapshot = GrokRateLimitReader.read(
            grokHome: fixture.root,
            now: try #require(GrokUsageAPI.parseISO8601("2026-08-30T10:00:00Z"))
        )
        #expect(snapshot.sevenDay?.utilization == 4)
    }
}

private struct GrokLogFixture {
    let root: URL
    let logFile: URL

    init(createLog: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokRateLimitReaderTests-\(UUID().uuidString)")
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        logFile = logs.appendingPathComponent("unified.jsonl")
        if createLog {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try Data().write(to: logFile)
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    func append(ts: String, percent: Double, start: String, end: String, tier: String) throws {
        let line = """
        {"ts":"\(ts)","src":"shell","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":\(percent),"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(start)","end":"\(end)"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"isUnifiedBillingUser":true},"subscriptionTier":"\(tier)"}}
        """
        try appendRaw(line)
    }

    func appendRaw(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: logFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
