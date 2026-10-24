import XCTest
@testable import VibeUsage

final class RuntimeDetectorTests: XCTestCase {
    func testExternalBundleUsesNpxPackageSyntaxForLocalTarball() {
        XCTAssertEqual(
            RuntimeDetector.arguments(
                runtimeName: "npx",
                command: ["quota", "discover", "--json"],
                packageSpecifier: "/Applications/Vibe Usage Test.app/Contents/Resources/vibe-usage-cli.tgz",
                usesBundledPackage: true
            ),
            [
                "--yes",
                "--package",
                "/Applications/Vibe Usage Test.app/Contents/Resources/vibe-usage-cli.tgz",
                "vibe-usage",
                "quota",
                "discover",
                "--json",
            ]
        )
    }

    func testBunUsesPinnedCompatiblePackage() {
        XCTAssertEqual(
            RuntimeDetector.arguments(runtimeName: "bun", command: ["sync"]),
            ["x", RuntimeDetector.packageSpecifier, "sync"]
        )
    }

    func testNpxUsesPinnedPackageForConfigCommands() {
        XCTAssertEqual(
            RuntimeDetector.arguments(runtimeName: "npx", command: ["config", "get", "apiKey"]),
            ["--yes", RuntimeDetector.packageSpecifier, "config", "get", "apiKey"]
        )
    }

    func testMacAppIdentityUsesTheDisplayVersion() {
        XCTAssertEqual(AppConfig.cliIdentityEnvironment["VIBE_USAGE_SURFACE"], "mac-app")
        XCTAssertEqual(AppConfig.cliIdentityEnvironment["VIBE_USAGE_SURFACE_VERSION"], AppConfig.version)
    }

    /// The nodejs.org installer (and Claude Code's native installer) place
    /// node in ~/.local/node with links in ~/.local/bin. A Finder-launched
    /// app does not inherit those from PATH, so the detector has to probe
    /// them explicitly.
    func testCandidatePathsCoverNodeOfficialInstallerLocations() {
        let paths = RuntimeDetector.candidatePaths(
            home: "/Users/example",
            environmentPath: "/usr/bin:/bin:/usr/sbin:/sbin"
        )

        XCTAssertTrue(paths.contains("/Users/example/.local/bin"))
        XCTAssertTrue(paths.contains("/Users/example/.local/node/bin"))
    }

    func testCandidatePathsKeepEnvironmentPathFirst() {
        let paths = RuntimeDetector.candidatePaths(
            home: "/Users/example",
            environmentPath: "/custom/bin:/usr/bin"
        )

        XCTAssertEqual(paths.first, "/custom/bin")
        XCTAssertEqual(paths[1], "/usr/bin")
    }

    func testCandidatePathsStillCoverExistingRuntimeManagers() {
        let paths = RuntimeDetector.candidatePaths(
            home: "/Users/example",
            environmentPath: ""
        )

        for expected in [
            "/Users/example/.bun/bin",
            "/Users/example/.volta/bin",
            "/Users/example/.fnm/current/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/local/bin",
        ] {
            XCTAssertTrue(paths.contains(expected), "missing \(expected)")
        }
    }
}
