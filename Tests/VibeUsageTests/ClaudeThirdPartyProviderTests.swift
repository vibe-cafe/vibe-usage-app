import Foundation
import Testing
@testable import VibeUsage

/// `ClaudeThirdPartyProvider`: a Bedrock / Vertex / … setup starts no probe.
/// Every case runs against a throwaway home and managed directory.
struct ClaudeThirdPartyProviderTests {

    private struct Sandbox {
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
        var managed: URL { root.appendingPathComponent("managed") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("vu-third-party-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func configured(_ environment: [String: String] = [:], profile: Any? = nil) -> Bool {
            ClaudeThirdPartyProvider.isConfigured(
                environment: environment, home: home, managedDirectory: managed, forcedManagedEnv: { profile })
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test
    func aSubscriptionLoginIsNotThirdParty() throws {
        let box = try Sandbox()
        defer { box.remove() }
        #expect(!box.configured())
        try box.write(#"{"env":{"ANTHROPIC_MODEL":"x","CLAUDE_CODE_USE_BEDROCK":""}}"#,
                      to: box.home.appendingPathComponent(".claude/settings.json"))
        #expect(!box.configured())
    }

    @Test
    func anySourceThatSelectsAProviderCounts() throws {
        let box = try Sandbox()
        defer { box.remove() }
        #expect(box.configured(["CLAUDE_CODE_USE_BEDROCK": "1"]))
        #expect(box.configured(["CLAUDE_CODE_USE_VERTEX": "0"]))
        #expect(box.configured(profile: ["CLAUDE_CODE_USE_FOUNDRY": "1"]))
        try box.write(#"{"env":{"AWS_REGION":"us-east-1","CLAUDE_CODE_USE_BEDROCK":"1"}}"#,
                      to: box.home.appendingPathComponent(".claude/settings.json"))
        #expect(box.configured())

        let other = try Sandbox()
        defer { other.remove() }
        try other.write(#"{"env":{"CLAUDE_CODE_USE_VERTEX":"true"}}"#,
                        to: other.managed.appendingPathComponent("managed-settings.d/10.json"))
        #expect(other.configured())
        let profileDir = other.root.appendingPathComponent("profile")
        try other.write(#"{"env":{"CLAUDE_CODE_USE_MANTLE":"1"}}"#, to: profileDir.appendingPathComponent("settings.json"))
        #expect(ClaudeThirdPartyProvider.isConfigured(
            environment: ["CLAUDE_CONFIG_DIR": profileDir.path], home: other.root.appendingPathComponent("nohome"),
            managedDirectory: other.root.appendingPathComponent("nomanaged"), forcedManagedEnv: { nil }))
    }
}
