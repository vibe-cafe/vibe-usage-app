import Foundation
import Testing
@testable import VibeUsage

@MainActor
func waitForDashboard(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(condition())
}

private final class ActivityProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        #expect(url.absoluteString.hasPrefix("https://example.test/team/api/usage/activity?"))
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let parameters = Dictionary(grouping: items, by: \.name).mapValues { $0.compactMap(\.value).sorted() }
        if parameters["from"] != nil {
            #expect(parameters == ["from": ["2026-11-21"], "to": ["2026-11-25"],
                                   "tz": [TimeZone.current.identifier], "granularity": ["day"]])
        } else {
            #expect(parameters == [
                "days": ["1"], "tz": [TimeZone.current.identifier], "granularity": ["hour"],
                "source": ["codex", "cursor"], "project": ["测试 & C++"], "hostname": ["Mac"],
            ])
            #expect(url.absoluteString.contains("C%2B%2B"))
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"activeSeconds":60,"workSeconds":90,"parallel":1.5,"series":[{"periodStart":"2026-11-25T00:00:00.000Z","activeSeconds":60,"workSeconds":90}],"firstBucketStart":"2026-11-24T00:30:00.000Z"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct UsageActivityTests {
    @Test func summaryAndTrendDistinguishMissingHistoryFromIdleTime() throws {
        let start = try #require(Formatters.dateFromISO8601("2026-11-25T00:00:00Z"))
        let first = "2026-11-25T03:30:00.000Z"
        let period = UsageActivity.Period(periodStart: "2026-11-25T03:00:00.000Z", activeSeconds: 40, workSeconds: 70)
        func report(first: String?, periods: [UsageActivity.Period]) -> ActivityReport {
            ActivityReport(UsageActivity(activeSeconds: periods.isEmpty ? 0 : 40, workSeconds: periods.isEmpty ? 0 : 70,
                                         parallel: periods.isEmpty ? nil : 1.8, series: periods, firstBucketStart: first),
                           rangeStart: start, hourly: true, timeZone: .gmt)
        }
        let full = report(first: "2026-11-24T20:00:00Z", periods: [period])
        #expect(full.summary?.activeText == "40s")
        #expect(full.summary?.workText == "AI 工时 1m")
        #expect(full.summary?.parallelText == "平均同时 1.8 个")
        #expect(full.coverageHint == nil)

        let partial = report(first: first, periods: [period])
        #expect(partial.summary == full.summary)
        #expect(partial.coverageHint == "2026-11-25 之前的记录无法重算")
        #expect(partial.time(in: "2026-11-25T02") == nil)
        #expect(partial.time(in: "2026-11-25T03") == full.summary)
        #expect(partial.time(in: "2026-11-25T04")?.activeText == "0s")
        #expect(partial.time(in: "2026-11-25T04")?.parallelText == nil)

        for missing in [report(first: nil, periods: []), report(first: first, periods: [])] {
            #expect(missing.summary == nil)
            #expect(missing.coverageHint == "更新后显示")
        }
        let idle = report(first: "2026-11-24T20:00:00Z", periods: [])
        #expect(idle.summary?.activeText == "0s")
        #expect(idle.summary?.workText == "AI 工时 0s")
        #expect(idle.summary?.parallelText == nil)
    }

    @Test func dailyActivityBelongsToLocalMidnight() throws {
        let date = "2026-11-24T16:00:00.000Z"
        let response = UsageActivity(activeSeconds: 3600, workSeconds: 5400, parallel: 1.5, series: [
            .init(periodStart: date, activeSeconds: 3600, workSeconds: 5400),
        ], firstBucketStart: date)
        let report = ActivityReport(response, rangeStart: .distantPast, hourly: false,
                                    timeZone: try #require(TimeZone(identifier: "Asia/Singapore")))
        #expect(report.time(in: "2026-11-24") == nil)
        #expect(report.time(in: "2026-11-25")?.activeText == "1h")
        #expect(report.time(in: "2026-11-25")?.workText == "AI 工时 1h 30m")
        #expect(report.coverageHint == "2026-11-25 之前的记录无法重算")
    }

    @Test func filteredRequestReadsModelTimeFromConfiguredServer() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ActivityProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = APIClient(server: UsageServer("https://example.test/team/"), apiKey: "fixture", session: session)
        let filters = FilterState(sources: ["cursor", "codex"], models: ["ignored"],
                                  projects: ["测试 & C++"], hostnames: ["Mac"])
        let result = try await client.fetchActivity(range: .days(1), filters: filters)
        #expect(result.activeSeconds == 60)
        #expect(result.workSeconds == 90)
        #expect(result.parallel == 1.5)
        #expect(result.series.first?.periodStart == "2026-11-25T00:00:00.000Z")
        let custom = UsageQueryRange.custom(from: try #require(Formatters.dateFromDayKey("2026-11-21")),
                                            to: try #require(Formatters.dateFromDayKey("2026-11-25")))
        _ = try await client.fetchActivity(range: custom, filters: FilterState())
    }
}
