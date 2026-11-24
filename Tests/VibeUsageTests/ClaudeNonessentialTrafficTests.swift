import Foundation
import Testing
@testable import VibeUsage

/// `ClaudeNonessentialTraffic`: the probe's quiet environment, and whether an
/// organization's policy forces Claude Code's nonessential traffic off. Every
/// file case runs against a throwaway managed directory, never the real one.
struct ClaudeNonessentialTrafficTests {

    private static let key = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"

    /// The master switch is cleared with an empty string (Claude Code counts
    /// `"0"` as on) and the separate switches the user may have meant are on.
    @Test
    func quietEnvironmentClearsOnlyTheMasterSwitch() {
        let env = ClaudeNonessentialTraffic.quietEnvironment
        #expect(env[Self.key] == "")
        for key in ["CLAUDE_CODE_DISABLE_FAST_MODE", "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_AUTOUPDATER",
                    "DISABLE_BUG_COMMAND", "DISABLE_UPDATES", "DISABLE_FEEDBACK_COMMAND",
                    "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY", "DISABLE_GROWTHBOOK",
                    "CLAUDE_CODE_DISABLE_FEATURE_FLAGS", "CLAUDE_CODE_DISABLE_VITALS_EMITTER",
                    "DISABLE_INSTALLATION_CHECKS",
                    "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL", "DO_NOT_TRACK"] {
            #expect(env[key] == "1", "\(key)")
        }
        #expect(env["CLAUDE_CODE_MODEL_CATALOG"] == "0")
        #expect(env.values.filter(\.isEmpty).count == 1)
    }

    @Test
    func probeSettingsCarryExactlyTheQuietEnvironment() throws {
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(ClaudeNonessentialTraffic.probeSettings.utf8)) as? [String: Any])
        #expect(object.count == 1)
        let env = try #require(object["env"] as? [String: String])
        #expect(env == ClaudeNonessentialTraffic.quietEnvironment)
    }

    private struct Sandbox {
        let root: URL
        var managed: URL { root.appendingPathComponent("managed") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("vu-nonessential-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func forced(_ profile: Any? = nil) -> Bool {
            ClaudeNonessentialTraffic.isForcedByPolicy(
                managedDirectory: managed, forcedManagedEnv: { profile })
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func settings(_ value: String) -> String {
        #"{"model":"x","env":{"ANTHROPIC_API_KEY":"secret","\#(key)":\#(value)}}"#
    }

    @Test
    func noPolicyByDefault() throws {
        let box = try Sandbox()
        defer { box.remove() }
        #expect(!box.forced())
        try box.write(#"{"env":{"OTHER":"1"}}"#, to: box.managed.appendingPathComponent("managed-settings.json"))
        #expect(!box.forced())
    }

    @Test
    func managedSettingsFileAndDropInsForceIt() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write(Self.settings(#""1""#), to: box.managed.appendingPathComponent("managed-settings.json"))
        #expect(box.forced())

        let other = try Sandbox()
        defer { other.remove() }
        try other.write(#"{"env":{}}"#, to: other.managed.appendingPathComponent("managed-settings.d/10-base.json"))
        #expect(!other.forced())
        try other.write(Self.settings(#""1""#), to: other.managed.appendingPathComponent("managed-settings.d/20-privacy.json"))
        #expect(other.forced())
        // Only `.json` drop-ins count, like Claude Code.
        let third = try Sandbox()
        defer { third.remove() }
        try third.write(Self.settings(#""1""#), to: third.managed.appendingPathComponent("managed-settings.d/notes.txt"))
        #expect(!third.forced())
    }

    /// Claude Code merges the files in order: a later drop-in that clears
    /// the key undoes the base file.
    @Test
    func aLaterDropInCanClearIt() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write(Self.settings(#""1""#), to: box.managed.appendingPathComponent("managed-settings.json"))
        try box.write(Self.settings(#""""#), to: box.managed.appendingPathComponent("managed-settings.d/50-lift.json"))
        #expect(!box.forced())
        try box.write(Self.settings(#""0""#), to: box.managed.appendingPathComponent("managed-settings.d/90-again.json"))
        #expect(box.forced())
    }

    /// A managed `env` merges key by key: a profile that sets the key wins
    /// (an explicit "" lifts the file's "1"); one that sets only other keys
    /// leaves it to the files.
    @Test
    func aForcedProfileOutranksTheFilesKeyByKey() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write(Self.settings(#""1""#), to: box.managed.appendingPathComponent("managed-settings.json"))
        #expect(box.forced())
        #expect(box.forced(["HTTPS_PROXY": "http://proxy.corp:3128"]))
        #expect(!box.forced([Self.key: ""]))
        #expect(box.forced([Self.key: "1"]))
    }

    @Test
    func forcedConfigurationProfileForcesIt() throws {
        let box = try Sandbox()
        defer { box.remove() }
        #expect(box.forced([Self.key: "1"]))
        #expect(box.forced([Self.key: "0"]))
        #expect(!box.forced([Self.key: ""]))
        #expect(!box.forced(["OTHER": "1"]))
        #expect(!box.forced("not a dictionary"))
    }

    @Test
    func emptyMissingOrUnreadableValuesDoNotCount() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let file = box.managed.appendingPathComponent("managed-settings.json")
        try box.write(Self.settings(#""""#), to: file)
        #expect(!box.forced())
        try box.write(Self.settings("null"), to: file)
        #expect(!box.forced())
        try box.write("{ not json", to: file)
        #expect(!box.forced())
        try box.write(#"{"env":"not an object"}"#, to: file)
        #expect(!box.forced())
        try box.write(Self.settings("true"), to: file)
        #expect(box.forced())
    }
}
