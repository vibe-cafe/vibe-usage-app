import Foundation
import Testing
@testable import VibeUsage

/// Opt-in end-to-end check against the Claude Code binaries actually installed
/// on this machine. Off by default — it spawns a real subprocess, needs a
/// logged-in Claude account, and reaches the network, none of which belong in
/// the normal suite or CI.
///
/// ```sh
/// VIBE_USAGE_LIVE_PROBE=1 swift test --filter ClaudeUsageProbeLiveTests
/// ```
///
/// Chiefly useful for confirming *which* install answers: discovery prefers a
/// user-installed CLI and only falls back to the copy bundled inside Claude
/// Desktop, and this prints the resolved list in order.
struct ClaudeUsageProbeLiveTests {

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["VIBE_USAGE_LIVE_PROBE"] == "1"
    }

    @Test(.enabled(if: ClaudeUsageProbeLiveTests.isEnabled))
    func discoversInstalledBinariesInPreferenceOrder() throws {
        let binaries = ClaudeUsageProbe.discoverBinaries()
        for binary in binaries {
            print("[live] candidate: \(binary.label) -> \(binary.url.path)")
        }
        print("[live] primary source: \(String(describing: ClaudeUsageProbe.primarySourceKind()))")
        #expect(!binaries.isEmpty)
    }

    @Test(.enabled(if: ClaudeUsageProbeLiveTests.isEnabled))
    func fetchesRealQuotaFromTheFirstWorkingBinary() async throws {
        let started = Date()
        let snapshot = try await ClaudeUsageProbe.fetch()
        let elapsed = Date().timeIntervalSince(started)

        print("""
        [live] plan=\(snapshot.planLabel ?? "?") \
        5h=\(snapshot.fiveHour.map { "\($0.utilization)%" } ?? "-") \
        7d=\(snapshot.sevenDay.map { "\($0.utilization)%" } ?? "-") \
        elapsed=\(String(format: "%.2f", elapsed))s
        """)

        #expect(snapshot.status == .ok)
        #expect(snapshot.fiveHour != nil || snapshot.sevenDay != nil)
    }

    /// The on-disk layers must work standalone too — they are what a machine
    /// without a usable binary falls back to.
    @Test(.enabled(if: ClaudeUsageProbeLiveTests.isEnabled))
    func readsWhateverCachesExistOnThisMachine() throws {
        let config = ClaudeUsageCache.configSnapshot()
        let desktop = ClaudeUsageCache.desktopHistorySnapshot()
        print("[live] ~/.claude.json -> \(config.map { "5h=\($0.fiveHour?.utilization ?? -1) asOf=\($0.dataAsOf?.description ?? "?")" } ?? "none")")
        print("[live] plan-usage-history -> \(desktop.map { "5h=\($0.fiveHour?.utilization ?? -1) asOf=\($0.dataAsOf?.description ?? "?")" } ?? "none")")
    }
}
