import Foundation
import Testing
@testable import VibeUsage

struct OpenCodeGoUsageAPITests {

    // MARK: - Response parsing

    /// The live shape: three dollar-denominated windows reported as a
    /// percentage consumed, each with its own reset instant.
    @Test
    func parsesRollingWeeklyAndMonthlyWindows() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let json = """
        {
          "usage": {
            "rolling": {
              "status": "ok",
              "percent": 4,
              "resetsAt": "2026-09-26T13:59:29.178Z"
            },
            "weekly": {
              "status": "ok",
              "percent": 12.5,
              "resetsAt": "2026-09-28T00:00:00.000Z"
            },
            "monthly": {
              "status": "ok",
              "percent": 2,
              "resetsAt": "2026-10-26T08:58:53.000Z"
            }
          }
        }
        """
        let snapshot = try #require(OpenCodeGoUsageAPI.parseUsageResponse(Data(json.utf8), now: now))

        #expect(snapshot.provider == .opencode)
        #expect(snapshot.status == .ok)
        #expect(snapshot.emptyReason == nil)
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.meters.map(\.id) == ["rolling", "weekly", "monthly"])
        #expect(snapshot.meters.map(\.label) == ["5h", "Weekly", "Monthly"])
        #expect(snapshot.meters[0].window.utilization == 4)
        #expect(snapshot.meters[0].window.windowDuration == 18_000)
        #expect(snapshot.meters[1].window.utilization == 12.5)
        #expect(snapshot.meters[1].window.windowDuration == 604_800)
        #expect(snapshot.meters[2].window.windowDuration == nil)
        #expect(snapshot.meters[0].window.resetsAt == Date(timeIntervalSince1970: 1_790_431_169.178))
    }

    /// Unknown keys and a partially populated payload stay usable: what the
    /// endpoint omits is simply not shown.
    @Test
    func parsesWindowsTheEndpointActuallyReturned() throws {
        let json = """
        { "usage": { "rolling": { "percent": 0, "resetsAt": "2026-09-26T13:59:29Z" },
                     "futureWindow": { "percent": 99, "resetsAt": "2026-11-01T00:00:00Z" } } }
        """
        let snapshot = try #require(OpenCodeGoUsageAPI.parseUsageResponse(Data(json.utf8)))
        #expect(snapshot.status == .ok)
        #expect(snapshot.meters.map(\.id) == ["rolling"])
        // ISO-8601 without fractional seconds is accepted too.
        #expect(snapshot.meters[0].window.resetsAt != nil)
    }

    /// A window that cannot be read is schema drift, not "0% used": rejecting
    /// the payload keeps the previous card instead of redrawing it at zero.
    @Test
    func rejectsPercentSchemaDrift() {
        let json = """
        { "usage": { "rolling": { "percent": "4", "resetsAt": "2026-09-26T13:59:29Z" } } }
        """
        #expect(OpenCodeGoUsageAPI.parseUsageResponse(Data(json.utf8)) == nil)
    }

    /// A 200 without `usage` is a shape we don't recognize; an empty `usage`
    /// object is the endpoint's own "no window applies" answer.
    @Test
    func distinguishesEmptyUsageFromUnknownPayloads() throws {
        #expect(OpenCodeGoUsageAPI.parseUsageResponse(Data(#"{"ok":true}"#.utf8)) == nil)

        let empty = try #require(OpenCodeGoUsageAPI.parseUsageResponse(Data(#"{"usage":{}}"#.utf8)))
        #expect(empty.status == .noData)
        #expect(empty.emptyReason == .noWindow)
        #expect(empty.meters.isEmpty)
    }

    @Test
    func clampsOutOfRangePercentages() throws {
        let json = #"{ "usage": { "rolling": { "percent": 140, "resetsAt": "2026-09-26T13:59:29Z" } } }"#
        let snapshot = try #require(OpenCodeGoUsageAPI.parseUsageResponse(Data(json.utf8)))
        #expect(snapshot.meters[0].window.utilization == 100)
    }

    // MARK: - Credentials

    /// The Go key lives beside OpenCode's other provider credentials; only the
    /// `opencode` entry is ever read.
    @Test
    func readsOnlyTheOpenCodeKeyEntry() throws {
        let data = Data("""
        { "opencode": { "type": "api", "key": "  sk-go-fixture  " },
          "anthropic": { "type": "oauth", "access": "must-not-be-read" } }
        """.utf8)
        #expect(OpenCodeGoUsageAPI.parseAuthFile(data) == "sk-go-fixture")
    }

    @Test
    func rejectsAuthFilesWithoutAUsableOpenCodeKey() {
        #expect(OpenCodeGoUsageAPI.parseAuthFile(Data(#"{"anthropic":{"type":"oauth","access":"x"}}"#.utf8)) == nil)
        #expect(OpenCodeGoUsageAPI.parseAuthFile(Data(#"{"opencode":{"type":"api","key":"   "}}"#.utf8)) == nil)
        #expect(OpenCodeGoUsageAPI.parseAuthFile(Data("not json".utf8)) == nil)
    }

    @Test
    func resolvesTheCLIDataHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(OpenCodeGoUsageAPI.dataHome.path == home.appendingPathComponent(".local/share/opencode").path)
        #expect(OpenCodeGoUsageAPI.authFileURL.lastPathComponent == "auth.json")
    }

    // MARK: - Failure semantics

    /// The coordinator's retry policy hangs off this mapping: an account
    /// without the Go plan must never turn into an endlessly retryable card,
    /// and a stale key must ask for a re-login rather than stay silent.
    @Test
    func mapsFailuresToTheSharedRetryPolicy() {
        #expect(OpenCodeGoUsageAPI.FetchError.notLoggedIn.rateLimitFailure == .absent)
        #expect(OpenCodeGoUsageAPI.FetchError.notSubscribed.rateLimitFailure == .notApplicable)
        #expect(OpenCodeGoUsageAPI.FetchError.unauthorized.rateLimitFailure == .unauthorized)
        #expect(OpenCodeGoUsageAPI.FetchError.badResponse(500).rateLimitFailure == .transient)
        #expect(OpenCodeGoUsageAPI.FetchError.unparseable.rateLimitFailure == .transient)
        #expect(OpenCodeGoUsageAPI.FetchError.transport(URLError(.timedOut)).rateLimitFailure == .transient)
    }

    @Test
    func pointsAtTheGoUsageEndpoint() {
        #expect(OpenCodeGoUsageAPI.usageURL.absoluteString == "https://opencode.ai/zen/go/v1/usage")
    }
}
