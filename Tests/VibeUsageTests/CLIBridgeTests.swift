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
}
