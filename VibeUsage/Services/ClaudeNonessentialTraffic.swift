import Foundation

/// How the Claude probe treats Claude Code's "nonessential traffic" switch
/// (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`) — network-privacy principle,
/// rules 4 and 6 (keep what the user switched off off, without losing the
/// quota card).
///
/// What the switch does, read from Claude Code 2.1.330 and measured with a
/// host-logging proxy (2026-11-24): it blocks every request Claude Code calls
/// nonessential, the usage read (`/api/oauth/usage`) included — with it on,
/// `get_usage` only answers from Claude Code's own snapshot, which nothing
/// refreshes. The documented equivalents (telemetry, error reporting, the
/// auto-updater, the bug command) and every other such feature that has a
/// switch of its own can be turned off one by one.
///
/// So the probe always runs with the master switch cleared and all those
/// separate switches on (`quietEnvironment`, passed both in the environment
/// and in an in-memory `--settings`, which outranks the user's files): every
/// feature that has a switch of its own stays off. What the master switch
/// alone would also have stopped is listed below.
/// Measured, the probe then reaches `api.anthropic.com` only: the usage read
/// plus the start-up configuration (`/api/claude_cli/bootstrap`), which no
/// separate switch covers — same host and same account. For an account in an
/// organization, Claude Code also refreshes its invite-eligibility record
/// there when the cached one is missing or stale.
///
/// Cleared only for the probe's own process and never written anywhere. An
/// organization's managed settings outrank `--settings`; when those force the
/// switch on (`isForcedByPolicy`), Claude Code cannot read the quota and the
/// app does not start it.
enum ClaudeNonessentialTraffic {
    static let variable = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    static let managedDirectoryPath = "/Library/Application Support/ClaudeCode"
    static let managedPreferencesDomain = "com.anthropic.claudecode"

    /// The probe's Claude Code environment: the master switch cleared (empty
    /// string — Claude Code counts any non-empty value as on, `"0"` included)
    /// and each separate off switch on. `CLAUDE_CODE_MODEL_CATALOG` is off
    /// with `"0"`.
    static let quietEnvironment: [String: String] = [
        variable: "",
        "CLAUDE_CODE_DISABLE_FAST_MODE": "1",
        "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1",
        "DISABLE_AUTOUPDATER": "1",
        "DISABLE_UPDATES": "1",
        "DISABLE_BUG_COMMAND": "1",
        "DISABLE_FEEDBACK_COMMAND": "1",
        "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1",
        "DISABLE_GROWTHBOOK": "1",
        "CLAUDE_CODE_DISABLE_FEATURE_FLAGS": "1",
        "CLAUDE_CODE_DISABLE_VITALS_EMITTER": "1",
        "CLAUDE_CODE_MODEL_CATALOG": "0",
        "DISABLE_INSTALLATION_CHECKS": "1",
        "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1",
        "DO_NOT_TRACK": "1",
    ]

    /// `--settings` for the probe: `{"env": quietEnvironment}`. Claude Code
    /// re-applies `env` from the user's settings files after spawn, so the
    /// process environment alone is not enough; flag settings outrank those
    /// files (not managed settings) and are never written to disk.
    static let probeSettings: String = {
        let data = try? JSONSerialization.data(
            withJSONObject: ["env": quietEnvironment], options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }()

    /// Whether the organization's managed settings force the switch on, read
    /// the way Claude Code picks its managed source: a configuration profile's
    /// forced `env` in `com.anthropic.claudecode` when there is one, else
    /// `/Library/Application Support/ClaudeCode/managed-settings.json` merged
    /// with every `managed-settings.d/*.json` after it (a later file that sets
    /// the key wins, `""` included). Those outrank the probe's `--settings`,
    /// so Claude Code could not read the quota. The user's own files and
    /// environment do not count here: the probe handles those.
    /// Server-managed settings from the claude.ai console are fetched by
    /// Claude Code and are not visible here; with those, the probe runs and
    /// Claude Code answers without windows.
    ///
    /// Only that one key is used. Each file is parsed in memory and the rest
    /// is dropped right away — never kept, logged, or put in diagnostics.
    static func isForcedByPolicy(
        managedDirectory: URL = URL(fileURLWithPath: managedDirectoryPath),
        forcedManagedEnv: () -> Any? = ClaudeNonessentialTraffic.forcedManagedPreferencesEnv,
        fileManager: FileManager = .default
    ) -> Bool {
        var files = [managedDirectory.appendingPathComponent("managed-settings.json")]
        let dropIns = (try? fileManager.contentsOfDirectory(
            at: managedDirectory.appendingPathComponent("managed-settings.d"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        files.append(contentsOf: dropIns
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent })

        if let profile = forcedManagedEnv() as? [String: Any] {
            return isOn(profile[variable])
        }
        var value: Any?
        for file in files {
            if let set = envValue(inSettingsFile: file) { value = set }
        }
        return isOn(value)
    }

    /// The `env` dictionary of a configuration profile, only when the profile
    /// forces it (MDM). A value the user wrote with `defaults` is not policy.
    static func forcedManagedPreferencesEnv() -> Any? {
        let key = "env" as CFString
        let domain = managedPreferencesDomain as CFString
        guard CFPreferencesAppValueIsForced(key, domain) else { return nil }
        return CFPreferencesCopyAppValue(key, domain)
    }

    /// The variable's value in one settings file's top-level `env` (`NSNull`
    /// for an explicit null), or nil when the file, the object or the key is
    /// missing or unreadable.
    static func envValue(inSettingsFile url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any]
        else { return nil }
        return env[variable]
    }

    /// Claude Code treats any non-empty value as set. A non-string value is
    /// not valid in `env`; it counts as set too.
    static func isOn(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let string = value as? String { return !string.isEmpty }
        return true
    }
}
