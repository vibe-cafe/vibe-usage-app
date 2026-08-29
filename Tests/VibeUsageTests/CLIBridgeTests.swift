import XCTest
@testable import VibeUsage

final class CLIBridgeTests: XCTestCase {
    func testDecodeRootsPreservesToolSpecificLists() throws {
        let roots = try CLIBridge.decodeRoots("""
        {
          "codex": ["/runtime/a", "/runtime/b"],
          "grok": ["/runtime/grok"],
          "antigravity": []
        }
        """)

        XCTAssertEqual(roots["codex"], ["/runtime/a", "/runtime/b"])
        XCTAssertEqual(roots["grok"], ["/runtime/grok"])
        XCTAssertEqual(roots["antigravity"], [])
    }

    func testConfigCommandsAgainstLocalCLI() async throws {
        guard ProcessInfo.processInfo.environment["VIBE_USAGE_CLI_PACKAGE"] != nil,
              ProcessInfo.processInfo.environment["VIBE_USAGE_CONFIG_DIR"] != nil else {
            throw XCTSkip("需要隔离配置目录和本地 CLI 路径")
        }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-cli-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let layouts = [
            ("codex", "codex/sessions"),
            ("grok", "grok/sessions"),
            ("antigravity", "agy/.gemini/antigravity/conversations"),
        ]

        for (_, relativePath) in layouts {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(relativePath),
                withIntermediateDirectories: true
            )
        }

        for (source, relativePath) in layouts {
            let root = base.appendingPathComponent(relativePath.components(separatedBy: "/").first!).path
            try await CLIBridge.configAddRoot(source: source, path: root)
        }

        let roots = try await CLIBridge.configRoots()
        XCTAssertEqual(roots["codex"], [base.appendingPathComponent("codex").path])
        XCTAssertEqual(roots["grok"], [base.appendingPathComponent("grok").path])
        XCTAssertEqual(roots["antigravity"], [base.appendingPathComponent("agy").path])

        try await CLIBridge.configRemoveRoot(
            source: "grok",
            path: base.appendingPathComponent("grok").path
        )
        let rootsAfterRemoval = try await CLIBridge.configRoots()
        XCTAssertNil(rootsAfterRemoval["grok"])
    }
}
