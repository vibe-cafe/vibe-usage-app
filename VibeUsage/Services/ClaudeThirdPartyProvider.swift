import Foundation

/// Whether the user's Claude Code is set up for a third-party model provider
/// (Bedrock, Vertex, Foundry, …). Such a login has no claude.ai plan limits,
/// so `get_usage` would only answer `rate_limits_available: false`; and while
/// starting, Claude Code 2.1.330 may first check model availability with the
/// user's cloud account (a one-token request). So the probe is not started at
/// all and the card says the login has no plan quota, as it did before
/// (network-privacy principle, rules 2 and 5).
///
/// Claude Code counts any non-empty value of these variables as on, so this
/// does too, from every place the probe's Claude Code would read them: the
/// app's environment, the user settings (`$CLAUDE_CONFIG_DIR/settings.json`,
/// else `~/.claude/settings.json`), the home directory's local settings (the
/// probe runs there), and the managed settings (files and a forced
/// configuration profile). Only these keys are used; each file is parsed in
/// memory and the rest is dropped right away.
enum ClaudeThirdPartyProvider {
    static let variables = [
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD", "CLAUDE_CODE_USE_MANTLE",
    ]

    static func isConfigured(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        managedDirectory: URL = URL(fileURLWithPath: ClaudeNonessentialTraffic.managedDirectoryPath),
        forcedManagedEnv: () -> Any? = ClaudeNonessentialTraffic.forcedManagedPreferencesEnv,
        fileManager: FileManager = .default
    ) -> Bool {
        if variables.contains(where: { !(environment[$0] ?? "").isEmpty }) { return true }

        var files: [URL] = []
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            files.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
                .appendingPathComponent("settings.json"))
        }
        let claude = home.appendingPathComponent(".claude")
        files.append(claude.appendingPathComponent("settings.json"))
        files.append(claude.appendingPathComponent("settings.local.json"))
        files.append(managedDirectory.appendingPathComponent("managed-settings.json"))
        let dropIns = (try? fileManager.contentsOfDirectory(
            at: managedDirectory.appendingPathComponent("managed-settings.d"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        files.append(contentsOf: dropIns.filter { $0.pathExtension == "json" })

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let env = root["env"] as? [String: Any]
            else { continue }
            if variables.contains(where: { ClaudeNonessentialTraffic.isOn(env[$0]) }) { return true }
        }
        let profile = forcedManagedEnv() as? [String: Any] ?? [:]
        return variables.contains { ClaudeNonessentialTraffic.isOn(profile[$0]) }
    }
}
