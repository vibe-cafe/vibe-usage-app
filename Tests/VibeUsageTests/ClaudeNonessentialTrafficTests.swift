import Foundation
import Testing
@testable import VibeUsage

/// `ClaudeNonessentialTraffic` decides whether the Claude probe may start
/// Claude Code at all. Every case runs against a throwaway home and managed
/// directory, never the real ones.
struct ClaudeNonessentialTrafficTests {

    private struct Sandbox {
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
        var managed: URL { root.appendingPathComponent("managed") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("vu-nonessential-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func disabled(
            environment: [String: String] = [:],
            forced: Any? = nil
        ) -> Bool {
            ClaudeNonessentialTraffic.isDisabledByUser(
                environment: environment,
                home: home,
                managedDirectory: managed,
                forcedManagedEnv: { forced }
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static let key = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"

    private static func settings(_ value: String) -> String {
        #"{"model":"x","env":{"ANTHROPIC_API_KEY":"secret","\#(key)":\#(value)}}"#
    }

    @Test
    func offWhenNoSourceSetsIt() throws {
        let box = try Sandbox()
        defer { box.remove() }
        #expect(!box.disabled())
        try box.write(#"{"env":{"OTHER":"1"}}"#, to: box.home.appendingPathComponent(".claude/settings.json"))
        #expect(!box.disabled())
    }

    /// Claude Code counts any non-empty value, `"0"` and `"false"` included.
    @Test
    func appEnvironmentCountsAnyNonEmptyValue() throws {
        let box = try Sandbox()
        defer { box.remove() }
        #expect(box.disabled(environment: [Self.key: "1"]))
        #expect(box.disabled(environment: [Self.key: "0"]))
        #expect(box.disabled(environment: [Self.key: "false"]))
        #expect(!box.disabled(environment: [Self.key: ""]))
    }

    @Test
    func userSettingsFileTurnsItOn() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write(Self.settings(#""1""#), to: box.home.appendingPathComponent(".claude/settings.json"))
        #expect(box.disabled())
    }

    @Test
    func claudeConfigDirSettingsFileTurnsItOn() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let profile = box.root.appendingPathComponent("profile")
        try box.write(Self.settings(#""1""#), to: profile.appendingPathComponent("settings.json"))
        #expect(box.disabled(environment: ["CLAUDE_CONFIG_DIR": profile.path]))
        // The same file is not consulted without the variable pointing at it.
        #expect(!box.disabled())
    }

    /// The probe runs with the home directory as its working directory, so
    /// `~/.claude/settings.local.json` is that project's local settings.
    @Test
    func homeProjectLocalSettingsTurnItOn() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write(Self.settings(#""true""#), to: box.home.appendingPathComponent(".claude/settings.local.json"))
        #expect(box.disabled())
    }

    @Test
    func managedSettingsFileAndDropInsTurnItOn() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write(Self.settings(#""1""#), to: box.managed.appendingPathComponent("managed-settings.json"))
        #expect(box.disabled())

        let other = try Sandbox()
        defer { other.remove() }
        try other.write(#"{"env":{}}"#, to: other.managed.appendingPathComponent("managed-settings.d/10-base.json"))
        #expect(!other.disabled())
        try other.write(Self.settings(#""1""#), to: other.managed.appendingPathComponent("managed-settings.d/20-privacy.json"))
        #expect(other.disabled())
        // Only `.json` drop-ins count, like Claude Code.
        let third = try Sandbox()
        defer { third.remove() }
        try third.write(Self.settings(#""1""#), to: third.managed.appendingPathComponent("managed-settings.d/notes.txt"))
        #expect(!third.disabled())
    }

    @Test
    func forcedConfigurationProfileTurnsItOn() throws {
        let box = try Sandbox()
        defer { box.remove() }
        #expect(box.disabled(forced: [Self.key: "1"]))
        #expect(!box.disabled(forced: [Self.key: ""]))
        #expect(!box.disabled(forced: ["OTHER": "1"]))
        #expect(!box.disabled(forced: "not a dictionary"))
    }

    @Test
    func emptyMissingOrUnreadableValuesDoNotCount() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let file = box.home.appendingPathComponent(".claude/settings.json")
        try box.write(Self.settings(#""""#), to: file)
        #expect(!box.disabled())
        try box.write(Self.settings("null"), to: file)
        #expect(!box.disabled())
        try box.write("{ not json", to: file)
        #expect(!box.disabled())
        try box.write(#"{"env":"not an object"}"#, to: file)
        #expect(!box.disabled())
    }

    /// `env` values should be strings. Anything else that is present errs
    /// towards not starting Claude Code.
    @Test
    func nonStringValuesCountAsOn() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let file = box.home.appendingPathComponent(".claude/settings.json")
        try box.write(Self.settings("1"), to: file)
        #expect(box.disabled())
        try box.write(Self.settings("true"), to: file)
        #expect(box.disabled())
    }
}
