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

    private static let now = Date(timeIntervalSince1970: 1_795_000_000)
    private static let laterMs = (now.timeIntervalSince1970 + 3_600) * 1000

    private func key(_ value: String, workspace: String? = nil) -> OpenCodeGoUsageAPI.Lookup {
        .found(.init(token: value, workspaceID: workspace))
    }

    /// The Go key lives beside OpenCode's other provider credentials; only the
    /// `opencode-go` and `opencode` entries are ever read, in that order.
    @Test
    func readsOnlyTheTwoOpenCodeEntriesOfAuthJSON() throws {
        let data = Data("""
        { "opencode": { "type": "api", "key": "  sk-zen-fixture  " },
          "anthropic": { "type": "oauth", "access": "must-not-be-read" },
          "opencode-go": { "type": "api", "key": "sk-go-fixture" } }
        """.utf8)
        #expect(OpenCodeGoUsageAPI.parseAuthFile(data, now: Self.now) == [key("sk-go-fixture"), key("sk-zen-fixture")])
    }

    @Test
    func rejectsAuthFilesWithoutAUsableOpenCodeKey() {
        func usable(_ json: String) -> Bool {
            OpenCodeGoUsageAPI.parseAuthFile(Data(json.utf8), now: Self.now).contains { if case .found = $0 { true } else { false } }
        }
        #expect(!usable(#"{"anthropic":{"type":"oauth","access":"x"}}"#))
        #expect(!usable(#"{"opencode":{"type":"api","key":"   "}}"#))
        #expect(!usable(#"{"opencode":{"type":"oauth","access":"a","refresh":"r","expires":0}}"#))
        #expect(!usable("not json"))
    }

    @Test
    func resolvesTheDataHomeLikeOpenCode() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        #expect(OpenCodeGoUsageAPI.dataHome(environment: [:], home: home).path == "/Users/example/.local/share/opencode")
        #expect(OpenCodeGoUsageAPI.dataHome(environment: ["XDG_DATA_HOME": "/tmp/xdg"], home: home).path == "/tmp/xdg/opencode")
        #expect(OpenCodeGoUsageAPI.dataHome(environment: ["XDG_DATA_HOME": ""], home: home).path == "/Users/example/.local/share/opencode")
        #expect(OpenCodeGoUsageAPI.authFileURL.lastPathComponent == "auth.json")
    }

    /// An OpenCode account login sends its workspace beside the token, as
    /// OpenCode itself does; a Go key is sent exactly as before.
    @Test
    func requestCarriesTheWorkspaceOnlyForAnAccountLogin() {
        let account = OpenCodeGoUsageAPI.request(for: .init(token: "acc-fixture", workspaceID: "wrk_fixture"))
        #expect(account.value(forHTTPHeaderField: "Authorization") == "Bearer acc-fixture")
        #expect(account.value(forHTTPHeaderField: "x-opencode-org-id") == "wrk_fixture")
        #expect(account.url == OpenCodeGoUsageAPI.usageURL)

        let goKey = OpenCodeGoUsageAPI.request(for: .init(token: "sk-go", workspaceID: nil))
        #expect(goKey.value(forHTTPHeaderField: "Authorization") == "Bearer sk-go")
        #expect(goKey.value(forHTTPHeaderField: "x-opencode-org-id") == nil)
    }

    // MARK: - Failure semantics

    /// The coordinator's retry policy hangs off this mapping: an account
    /// without the Go plan must never turn into an endlessly retryable card,
    /// and a stale key must ask for a re-login rather than stay silent.
    @Test
    func mapsFailuresToTheSharedRetryPolicy() {
        #expect(OpenCodeGoUsageAPI.FetchError.notLoggedIn.rateLimitFailure == .absent)
        #expect(OpenCodeGoUsageAPI.FetchError.signInExpired.rateLimitFailure == .absent)
        #expect(OpenCodeGoUsageAPI.FetchError.notLoggedIn.liveFailure == .credentialsNotFound)
        #expect(OpenCodeGoUsageAPI.FetchError.signInExpired.liveFailure == .credentialsExpired)
        #expect(OpenCodeGoUsageAPI.FetchError.unauthorized.liveFailure == .credentialsRejected)
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

    private func addMigrations(_ ids: [String], to root: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("opencode.db").path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "sqlite", code: 1)
        }
        defer { sqlite3_close(handle) }
        try exec(handle, "CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);")
        for id in ids { try exec(handle, "INSERT INTO migration VALUES ('\(id)', 1);") }
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func accountLogin(access: String = "acc-fixture", workspace: String? = "wrk_fixture",
                              expiresMs: Double = OpenCodeGoUsageAPITests.laterMs, server: String? = nil) -> String {
        var metadata: [String: Any] = [:]
        if let workspace { metadata["orgID"] = workspace }
        if let server { metadata["server"] = server }
        let value: [String: Any] = ["type": "oauth", "methodID": "device", "refresh": "ref-must-not-leave",
                                    "access": access, "expires": expiresMs, "metadata": metadata]
        let data = try! JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }

    private func store(table: [(integration: String, value: String, active: Int)] = [], authJSON: String? = nil) throws -> URL {
        let root = try temporaryDirectory()
        if !table.isEmpty {
            try createCredentialDatabase(at: root.appendingPathComponent("opencode.db"), rows: table)
        }
        if let authJSON {
            try Data(authJSON.utf8).write(to: root.appendingPathComponent("auth.json"))
        }
        return root
    }

    private func lookup(_ root: URL) -> OpenCodeGoUsageAPI.Lookup {
        OpenCodeGoUsageAPI.loadCredential(dataHome: root, now: Self.now)
    }

    /// 1.x, connected through "OpenCode Go" as the official docs describe.
    @Test
    func readsA1xLoginMadeThroughOpenCodeGo() throws {
        let root = try store(authJSON: #"{"opencode-go":{"type":"api","key":"sk-go-file"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(lookup(root) == key("sk-go-file"))
    }

    /// 1.x, connected through "OpenCode" with the same workspace key.
    @Test
    func readsA1xLoginMadeThroughOpenCode() throws {
        let root = try store(table: [("anthropic", #"{"type":"oauth","access":"x"}"#, 1)],
                             authJSON: #"{"opencode":{"type":"api","key":"sk-auth-file"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(lookup(root) == key("sk-auth-file"))
    }

    /// 2.0–2.3: the Go key in the credential table's own `opencode-go` row.
    @Test
    func readsTheGoKeyFromTheCredentialTable() throws {
        let root = try store(table: [
            ("anthropic", #"{"type":"oauth","access":"must-not-be-read"}"#, 1),
            ("opencode-go", #"{"type":"key","key":"  sk-go-table  "}"#, 1),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(lookup(root) == key("sk-go-table"))
    }

    /// 2.4+: an OpenCode account sign-in, the only option new users get.
    @Test
    func readsAnOpenCodeAccountSignInWithItsWorkspace() throws {
        let root = try store(table: [("opencode", accountLogin(), 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(lookup(root) == key("acc-fixture", workspace: "wrk_fixture"))
    }

    /// 2.x: "API key (service account)" under the OpenCode integration.
    @Test
    func readsAnOpenCodeServiceAccountKey() throws {
        let root = try store(table: [("opencode", #"{"type":"key","key":"sk-service","metadata":{"orgID":"wrk_service"}}"#, 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(lookup(root) == key("sk-service", workspace: "wrk_service"))
    }

    /// Never renewed here: an expired (or nearly expired) sign-in is reported
    /// as expired so nothing is sent until OpenCode renews it.
    @Test
    func reportsAnExpiredSignInWithoutUsingIt() throws {
        let nowMs = Self.now.timeIntervalSince1970 * 1000
        let expired = try store(table: [("opencode", accountLogin(expiresMs: nowMs - 1_000), 1)])
        let margin = try store(table: [("opencode", accountLogin(expiresMs: nowMs + 30_000), 1)])
        let forever = try store(table: [("opencode", accountLogin(expiresMs: 0), 1)])
        defer { [expired, margin, forever].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(lookup(expired) == .expired)
        #expect(lookup(margin) == .expired)
        #expect(lookup(forever) == key("acc-fixture", workspace: "wrk_fixture"))
    }

    @Test
    func skipsAnAccountSignInWithoutAWorkspaceOrForAnotherConsole() throws {
        let noWorkspace = try store(table: [("opencode", accountLogin(workspace: nil), 1)])
        let custom = try store(table: [("opencode", accountLogin(server: "https://console.example.com"), 1)])
        let retired = try store(table: [("opencode", accountLogin(server: "https://console.opencode.ai"), 1)])
        defer { [noWorkspace, custom, retired].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(lookup(noWorkspace) == .missing)
        #expect(lookup(custom) == .missing)
        #expect(lookup(retired) == key("acc-fixture", workspace: "wrk_fixture"))
    }

    @Test
    func prefersAGoKeyOverAnAccountSignInWhenBothAreStored() throws {
        let root = try store(table: [
            ("opencode", accountLogin(), 1),
            ("opencode-go", #"{"type":"key","key":"sk-go-table"}"#, 1),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(lookup(root) == key("sk-go-table"))
    }

    /// 2.x leaves the 1.x auth.json behind after importing it; once the table
    /// holds an OpenCode login, that stale file never stands in for it.
    @Test
    func reportsExpiryInsteadOfUsingALeftoverAuthJSON() throws {
        let nowMs = Self.now.timeIntervalSince1970 * 1000
        let root = try store(table: [("opencode", accountLogin(expiresMs: nowMs - 1), 1)],
                             authJSON: #"{"opencode-go":{"type":"api","key":"sk-go-file"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(lookup(root) == .expired)
    }

    @Test
    func ignoresAuthJSONOnceOpenCode2xImportedIt() throws {
        let imported = try store(table: [("anthropic", #"{"type":"key","key":"x"}"#, 1)],
                                 authJSON: #"{"opencode-go":{"type":"api","key":"sk-go-file"}}"#)
        try addMigrations(["20260805200742_import_legacy_credentials"], to: imported)
        // 1.x: the table exists but stays empty and that migration never runs.
        let legacy = try store(authJSON: #"{"opencode-go":{"type":"api","key":"sk-go-file"}}"#)
        try createCredentialDatabase(at: legacy.appendingPathComponent("opencode.db"), rows: [])
        try addMigrations(["20260622202450_simplify_session_input"], to: legacy)
        defer { [imported, legacy].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(lookup(imported) == .missing)
        #expect(lookup(legacy) == key("sk-go-file"))
    }

    @Test
    func sendsAnOpenCodeKeyOnlyToItsOwnConsole() throws {
        let custom = try store(table: [("opencode",
            #"{"type":"key","key":"sk-custom","metadata":{"orgID":"wrk_x","server":"https://console.example.com"}}"#, 1)])
        // A 1.x "OpenCode" key imported by 2.x has no workspace and still works.
        let imported = try store(table: [("opencode", #"{"type":"key","key":"sk-imported"}"#, 1)])
        defer { [custom, imported].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(lookup(custom) == .missing)
        #expect(lookup(imported) == key("sk-imported"))
    }

    @Test
    func acceptsTheDefaultConsoleWithAnExplicitPort() {
        #expect(OpenCodeGoUsageAPI.isDefaultConsole(nil))
        #expect(OpenCodeGoUsageAPI.isDefaultConsole("https://opencode.ai/console"))
        #expect(OpenCodeGoUsageAPI.isDefaultConsole("https://opencode.ai:443/console"))
        #expect(OpenCodeGoUsageAPI.isDefaultConsole("https://console.opencode.ai"))
        #expect(!OpenCodeGoUsageAPI.isDefaultConsole("https://opencode.ai:8443/console"))
        #expect(!OpenCodeGoUsageAPI.isDefaultConsole("http://opencode.ai/console"))
        #expect(!OpenCodeGoUsageAPI.isDefaultConsole("https://console.example.com"))
    }

    @Test
    func picksTheActiveAccountRowAndTheNewestAmongEquals() throws {
        let root = try store(table: [
            ("opencode", accountLogin(access: "acc-active"), 1),
            ("opencode", accountLogin(access: "acc-inactive"), 0),
        ])
        // Rows later in the fixture are newer (larger time_updated).
        let equals = try store(table: [
            ("opencode", accountLogin(access: "acc-older"), 1),
            ("opencode", accountLogin(access: "acc-newer"), 1),
        ])
        defer { [root, equals].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(lookup(root) == key("acc-active", workspace: "wrk_fixture"))
        #expect(lookup(equals) == key("acc-newer", workspace: "wrk_fixture"))
    }

    @Test
    func ignoresStoresWithoutAUsableLogin() throws {
        let unusable = try store(table: [
            ("anthropic", #"{"type":"oauth","access":"x"}"#, 1),
            ("opencode-go", "not json", 1),
        ], authJSON: #"{"opencode":{"type":"api","key":"   "}}"#)
        let empty = try temporaryDirectory()
        let foreign = try temporaryDirectory()
        try Data("not a sqlite database".utf8).write(to: foreign.appendingPathComponent("opencode.db"))
        defer { [unusable, empty, foreign].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(lookup(unusable) == .missing)
        #expect(lookup(empty) == .missing)
        #expect(lookup(foreign) == .missing)
    }

    /// An unreadable database cannot hide a perfectly good 1.x login.
    @Test
    func fallsBackToAuthJSONWhenTheDatabaseIsUnreadable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a sqlite database".utf8).write(to: root.appendingPathComponent("opencode.db"))
        try Data(#"{"opencode":{"type":"api","key":"sk-auth-file"}}"#.utf8).write(to: root.appendingPathComponent("auth.json"))
        #expect(lookup(root) == key("sk-auth-file"))
    }
}
