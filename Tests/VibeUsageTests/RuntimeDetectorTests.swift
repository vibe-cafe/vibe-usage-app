import XCTest
@testable import VibeUsage

final class RuntimeDetectorTests: XCTestCase {
    func testBunUsesExplicitLatestPackage() {
        XCTAssertEqual(
            RuntimeDetector.arguments(runtimeName: "bun", command: ["sync"]),
            ["x", "@vibe-cafe/vibe-usage@latest", "sync"]
        )
    }

    func testNpxUsesExplicitLatestPackageForConfigCommands() {
        XCTAssertEqual(
            RuntimeDetector.arguments(runtimeName: "npx", command: ["config", "get", "apiKey"]),
            ["--yes", "@vibe-cafe/vibe-usage@latest", "config", "get", "apiKey"]
        )
    }

    func testMacAppIdentityUsesTheDisplayVersion() {
        XCTAssertEqual(AppConfig.cliIdentityEnvironment["VIBE_USAGE_SURFACE"], "mac-app")
        XCTAssertEqual(AppConfig.cliIdentityEnvironment["VIBE_USAGE_SURFACE_VERSION"], AppConfig.version)
    }
}
