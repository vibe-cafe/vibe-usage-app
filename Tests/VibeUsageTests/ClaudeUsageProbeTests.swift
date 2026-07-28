import Foundation
import Testing
@testable import VibeUsage

struct ClaudeUsageProbeTests {

    /// Verbatim shape of a real `get_usage` control response (trimmed to the
    /// fields we read), so schema drift in the binary shows up as a test failure
    /// rather than a silently empty card.
    private func payload(
        fiveHourUtilization: Double = 33,
        fiveHourResetsAt: String = "2026-07-28T05:20:00.420021+00:00",
        subscriptionType: String = "pro",
        limitsAvailable: Bool = true
    ) -> [String: Any] {
        [
            "session": ["total_cost_usd": 0],
            "subscription_type": subscriptionType,
            "rate_limits_available": limitsAvailable,
            "rate_limits": [
                "five_hour": [
                    "utilization": fiveHourUtilization,
                    "resets_at": fiveHourResetsAt,
                ],
                "seven_day": [
                    "utilization": 16,
                    "resets_at": "2026-08-01T20:00:00.420040+00:00",
                ],
                "seven_day_opus": NSNull(),
                "extra_usage": [
                    "is_enabled": true,
                    "monthly_limit": 200_000,
                    "used_credits": 2_500,
                ],
            ],
        ]
    }

    private let now = ISO8601DateFormatter().date(from: "2026-07-28T04:00:00Z")!

    @Test
    func parsesLiveWindowsWithResetTimes() throws {
        let snapshot = try #require(
            ClaudeUsageProbe.parse(payload(), now: now)
        )

        #expect(snapshot.provider == .claudeCode)
        #expect(snapshot.status == .ok)
        #expect(snapshot.planLabel == "Pro")
        #expect(snapshot.fiveHour?.utilization == 33)
        #expect(snapshot.sevenDay?.utilization == 16)
        // A live reading is current by definition — no 「数据截至」 note.
        #expect(snapshot.dataAsOf == now)
    }

    /// The window length is what enables the elapsed-time bar, and it may only
    /// be published when the reset still lies ahead.
    @Test
    func futureResetEnablesTheElapsedTimeBar() throws {
        let snapshot = try #require(ClaudeUsageProbe.parse(payload(), now: now))
        #expect(snapshot.fiveHour?.windowDuration == ClaudeUsageProbe.fiveHourDuration)
        #expect(snapshot.sevenDay?.windowDuration == ClaudeUsageProbe.sevenDayDuration)
    }

    /// A snapshot whose reset has already passed keeps its percentage but must
    /// lose the window length, or the time bar would pin to a wrong 100%.
    @Test
    func alreadyResetWindowDropsItsDurationButKeepsUtilization() throws {
        let stale = payload(fiveHourResetsAt: "2026-07-28T03:00:00Z")
        let snapshot = try #require(ClaudeUsageProbe.parse(stale, now: now))

        #expect(snapshot.fiveHour?.utilization == 33)
        #expect(snapshot.fiveHour?.windowDuration == nil)
    }

    @Test
    func extraUsageCreditsAreConvertedFromMinorUnits() throws {
        let snapshot = try #require(ClaudeUsageProbe.parse(payload(), now: now))
        #expect(snapshot.extraUsage?.isEnabled == true)
        #expect(snapshot.extraUsage?.spend == 25)
        #expect(snapshot.extraUsage?.limit == 2_000)
    }

    /// API key / Bedrock / Vertex sessions: plan limits genuinely do not apply.
    /// This is a permanent answer, and must be distinguishable from a failed
    /// fetch so the coordinator doesn't keep retrying it.
    @Test
    func apiKeySessionsAreReportedAsNotApplicable() {
        let apiKeySession: [String: Any] = [
            "subscription_type": NSNull(),
            "rate_limits_available": false,
            "rate_limits": NSNull(),
        ]
        #expect(ClaudeUsageProbe.limitsAreNotApplicable(apiKeySession))
        #expect(!ClaudeUsageProbe.limitsAreNotApplicable(payload()))
    }

    /// `rate_limits: null` on a subscription account means the binary's own
    /// fetch failed — retryable, and never parsed into an empty ".ok" card.
    @Test
    func nullRateLimitsProducesNoSnapshot() {
        let failedFetch: [String: Any] = [
            "subscription_type": "pro",
            "rate_limits_available": true,
            "rate_limits": NSNull(),
        ]
        #expect(ClaudeUsageProbe.parse(failedFetch, now: now) == nil)
    }

    /// A user-installed CLI must win over the copy bundled inside Claude
    /// Desktop: the Desktop bundle exists to cover machines that have no CLI at
    /// all, and must not quietly take over on machines that do.
    @Test
    func cliIsPreferredAndDesktopBundleIsOnlyAFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageProbeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let desktop = root
            .appendingPathComponent("Library/Application Support/Claude/claude-code/2.1.219/claude.app/Contents/MacOS")
        let cli = root.appendingPathComponent(".local/bin")
        for dir in [desktop, cli] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func makeExecutable(_ url: URL) throws {
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try makeExecutable(desktop.appendingPathComponent("claude"))
        try makeExecutable(cli.appendingPathComponent("claude"))

        let fileManager = HomeOverridingFileManager(home: root)

        let both = ClaudeUsageProbe.discoverBinaries(fileManager: fileManager, environment: [:])
        #expect(both.map(\.kind) == [.cli, .desktop])
        #expect(ClaudeUsageProbe.primarySourceKind(fileManager: fileManager, environment: [:]) == .cli)

        // Remove the CLI: only then does the Desktop bundle become the source,
        // which is what Settings surfaces as 「数据来源：Claude Desktop」.
        try FileManager.default.removeItem(at: cli.appendingPathComponent("claude"))
        let desktopOnly = ClaudeUsageProbe.discoverBinaries(fileManager: fileManager, environment: [:])
        #expect(desktopOnly.map(\.kind) == [.desktop])
        #expect(ClaudeUsageProbe.primarySourceKind(fileManager: fileManager, environment: [:]) == .desktop)
    }

    @Test
    func explicitOverrideOutranksEverythingElse() throws {
        let binary = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-override-\(UUID().uuidString)")
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        defer { try? FileManager.default.removeItem(at: binary) }

        let found = ClaudeUsageProbe.discoverBinaries(
            environment: ["VIBE_USAGE_CLAUDE_BIN": binary.path]
        )
        #expect(found.first?.kind == .override)
        #expect(found.first?.url == binary)
    }

    @Test
    func versionDirectoriesSortNumericallyNotLexically() {
        #expect(ClaudeUsageProbe.isVersion("2.1.220", newerThan: "2.1.9"))
        #expect(ClaudeUsageProbe.isVersion("2.2.0", newerThan: "2.1.220"))
        #expect(!ClaudeUsageProbe.isVersion("2.1.219", newerThan: "2.1.219"))
    }

    @Test
    func iso8601IsParsedWithAndWithoutFractionalSeconds() {
        #expect(ClaudeUsageProbe.parseISO8601("2026-07-28T05:20:00.420021+00:00") != nil)
        #expect(ClaudeUsageProbe.parseISO8601("2026-07-28T05:20:00Z") != nil)
        #expect(ClaudeUsageProbe.parseISO8601("") == nil)
    }
}

/// Redirects `homeDirectoryForCurrentUser` at a fixture tree so binary
/// discovery can be exercised without depending on what is installed on the
/// machine running the tests.
private final class HomeOverridingFileManager: FileManager, @unchecked Sendable {
    private let home: URL

    init(home: URL) {
        self.home = home
        super.init()
    }

    override var homeDirectoryForCurrentUser: URL { home }
}
