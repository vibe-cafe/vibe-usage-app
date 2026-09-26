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

        #expect(snapshot.provider == .opencodeGo)
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

// MARK: - Credential sources

import SQLite3

extension OpenCodeGoUsageAPITests {
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenCodeGoUsageAPITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createCredentialDatabase(at url: URL, rows: [(integration: String, value: String, active: Int)]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "sqlite", code: 1)
        }
        defer { sqlite3_close(handle) }
        try exec(handle, """
            CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, value TEXT, active INTEGER, time_updated INTEGER);
            """)
        for (index, row) in rows.enumerated() {
            let escaped = row.value.replacingOccurrences(of: "'", with: "''")
            try exec(handle, """
                INSERT INTO credential VALUES ('cred-\(index)', '\(row.integration)', '\(escaped)', \(row.active), \(index));
                """)
        }
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// The 2.x layout keeps the Go key in the credential table's own
    /// `opencode-go` row; that row is read on its own, nothing else in the row.
    @Test
    func readsTheGoKeyFromTheCredentialTable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("opencode.db")
        try createCredentialDatabase(at: url, rows: [
            ("anthropic", #"{"type":"oauth","access":"must-not-be-read"}"#, 1),
            ("opencode-go", #"{"type":"key","key":"  sk-go-table  "}"#, 1),
        ])
        #expect(OpenCodeGoUsageAPI.loadCredentialTableKey(databaseURL: url) == "sk-go-table")
    }

    @Test
    func ignoresCredentialTablesWithoutAUsableGoRow() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("opencode.db")
        try createCredentialDatabase(at: url, rows: [
            ("anthropic", #"{"type":"oauth","access":"x"}"#, 1),
            ("opencode-go", "not json", 1),
            ("opencode-go", #"{"type":"key","key":"   "}"#, 1),
        ])
        #expect(OpenCodeGoUsageAPI.loadCredentialTableKey(databaseURL: url) == nil)
    }

    @Test
    func returnsNilInsteadOfThrowingForMissingOrForeignStores() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(OpenCodeGoUsageAPI.loadCredentialTableKey(databaseURL: root.appendingPathComponent("absent.db")) == nil)

        let foreign = root.appendingPathComponent("opencode.db")
        try Data("not a sqlite database".utf8).write(to: foreign)
        #expect(OpenCodeGoUsageAPI.loadCredentialTableKey(databaseURL: foreign) == nil)
    }

    /// Source precedence matches the CLI's adapter: the Go-specific table row
    /// wins, and `auth.json` (the pre-2.x home for the same key) is the fallback.
    @Test
    func prefersTheCredentialTableAndFallsBackToAuthJSON() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createCredentialDatabase(at: root.appendingPathComponent("opencode.db"), rows: [
            ("opencode-go", #"{"type":"key","key":"sk-go-table"}"#, 1),
        ])
        try Data(#"{"opencode":{"type":"api","key":"sk-auth-file"}}"#.utf8)
            .write(to: root.appendingPathComponent("auth.json"))
        #expect(OpenCodeGoUsageAPI.loadAPIKey(dataHome: root) == "sk-go-table")

        // 1.x home: no Go row at all, only auth.json.
        let legacy = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: legacy) }
        try createCredentialDatabase(at: legacy.appendingPathComponent("opencode.db"), rows: [
            ("anthropic", #"{"type":"oauth","access":"x"}"#, 1),
        ])
        try Data(#"{"opencode":{"type":"api","key":"sk-auth-file"}}"#.utf8)
            .write(to: legacy.appendingPathComponent("auth.json"))
        #expect(OpenCodeGoUsageAPI.loadAPIKey(dataHome: legacy) == "sk-auth-file")

        // Neither source: no login, no throw.
        let empty = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(OpenCodeGoUsageAPI.loadAPIKey(dataHome: empty) == nil)
    }
}
