import Foundation

/// Whether the user switched off Claude Code's "nonessential traffic"
/// (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`).
///
/// With that switch on, Claude Code answers `get_usage` with
/// `rate_limits: null`, so a probe cannot produce numbers — it would only add
/// one more signed-in launch of Claude Code. The probe used to unset the
/// switch for its own process (`--settings`), which turned back on traffic the
/// user had turned off. The network-privacy principle (rule 4: never change a
/// user's setting, including inside the processes we start) forbids that, so
/// the app now checks first and, when the switch is on, does not start Claude
/// Code at all; the card says why.
///
/// Claude Code counts any non-empty value as "on", `"0"` and `"false"`
/// included, so this does too. Sources, matching where the probe's Claude Code
/// would read the variable (it runs with the home directory as its working
/// directory):
///
/// - the app's own environment;
/// - user settings: `$CLAUDE_CONFIG_DIR/settings.json`, else
///   `~/.claude/settings.json`;
/// - project settings for the home directory: `~/.claude/settings.json` and
///   `~/.claude/settings.local.json`;
/// - managed settings: `/Library/Application Support/ClaudeCode/managed-settings.json`,
///   every `managed-settings.d/*.json` beside it, and a configuration
///   profile's forced `env` in the `com.anthropic.claudecode` domain.
///
/// "On in any source" counts as on. Claude Code itself resolves the levels by
/// precedence, so a higher level that sets the variable to an empty string
/// would switch it back off there; treating that rare setup as "on" errs
/// towards not starting Claude Code. Server-managed settings from the
/// claude.ai console are fetched by Claude Code and are not visible here; with
/// those, the probe still runs and Claude Code answers without windows.
///
/// Only the one key is read. Nothing else in these files (which can hold API
/// keys in `env`) is parsed out, kept, logged, or put in diagnostics.
enum ClaudeNonessentialTraffic {
    static let variable = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    static let managedDirectoryPath = "/Library/Application Support/ClaudeCode"
    static let managedPreferencesDomain = "com.anthropic.claudecode"

    static func isDisabledByUser(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        managedDirectory: URL = URL(fileURLWithPath: managedDirectoryPath),
        forcedManagedEnv: () -> Any? = ClaudeNonessentialTraffic.forcedManagedPreferencesEnv,
        fileManager: FileManager = .default
    ) -> Bool {
        if isOn(environment[variable]) { return true }

        var files: [URL] = []
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            files.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
                .appendingPathComponent("settings.json"))
        }
        let claudeDirectory = home.appendingPathComponent(".claude")
        files.append(claudeDirectory.appendingPathComponent("settings.json"))
        files.append(claudeDirectory.appendingPathComponent("settings.local.json"))
        files.append(managedDirectory.appendingPathComponent("managed-settings.json"))
        let dropIns = (try? fileManager.contentsOfDirectory(
            at: managedDirectory.appendingPathComponent("managed-settings.d"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        files.append(contentsOf: dropIns
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent })

        for file in files where isOn(envValue(inSettingsFile: file)) {
            return true
        }
        return isOn((forcedManagedEnv() as? [String: Any])?[variable])
    }

    /// The `env` dictionary of a configuration profile, only when the profile
    /// forces it (MDM). A value the user wrote with `defaults` is not policy.
    static func forcedManagedPreferencesEnv() -> Any? {
        let key = "env" as CFString
        let domain = managedPreferencesDomain as CFString
        guard CFPreferencesAppValueIsForced(key, domain) else { return nil }
        return CFPreferencesCopyAppValue(key, domain)
    }

    /// The variable's value in one settings file's top-level `env`, or nil
    /// when the file, the object or the key is missing or unreadable.
    static func envValue(inSettingsFile url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any]
        else { return nil }
        return env[variable]
    }

    /// Claude Code treats any non-empty value as set. A non-string value is
    /// not valid in `env`; it counts as set too, erring towards not starting
    /// Claude Code.
    static func isOn(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let string = value as? String { return !string.isEmpty }
        return true
    }
}
