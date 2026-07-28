import Foundation

/// One-time cleanup for the statusline capture hook shipped in earlier releases.
///
/// Up to 0.5.6 the Claude quota card was fed by a wrapper we installed into
/// Claude Code's `statusLine.command`, which teed the `rate_limits` slice of the
/// statusline payload to `~/.vibe-usage/claude-rate-limits.json`. That approach
/// had a ceiling we could not raise: the statusline is built inside Claude
/// Code's *terminal* render loop, so the Claude Desktop app — which hosts
/// sessions through the SDK — never invoked the wrapper at all. Desktop-only
/// users could never see a quota number.
///
/// `ClaudeUsageProbe` + `ClaudeUsageCache` replaced it and need no hook, so the
/// edit we made to the user's `~/.claude/settings.json` has to be handed back.
/// This runs on every launch but is a cheap no-op once there is nothing left to
/// undo, and it deliberately never *writes* anything except to restore the
/// user's own command.
enum LegacyStatuslineRetirement {

    /// Honor CLAUDE_CONFIG_DIR (some users relocate ~/.claude), matching what
    /// the installer did.
    private static var claudeDir: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
    }

    private static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }

    private static var vibeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe-usage")
    }

    private static var wrapperURL: URL { vibeDir.appendingPathComponent("vibe-usage-statusline.sh") }
    private static var sidecarURL: URL { vibeDir.appendingPathComponent("statusline-original") }
    private static var captureURL: URL { vibeDir.appendingPathComponent("claude-rate-limits.json") }

    /// The exact command the installer wrote. Matched literally so we only ever
    /// touch a `statusLine.command` we know we own.
    private static var wrapperCommand: String {
        "bash \"\(wrapperURL.path)\""
    }

    /// Restore the user's original statusline command and delete the files the
    /// old implementation generated. Safe to call repeatedly.
    ///
    /// `settings.json.vibe-bak` is deliberately *not* removed: it is a copy of
    /// the user's own settings from before we ever edited them, and it is the
    /// only record left if the sidecar went missing and the restore below had
    /// to drop `statusLine` outright. Everything else here is our own generated
    /// scaffolding and is now dead.
    static func run() {
        let fileManager = FileManager.default
        let generated = [wrapperURL, sidecarURL, captureURL]
            .filter { fileManager.fileExists(atPath: $0.path) }

        // Fast path: nothing generated and no settings edit to undo. Avoids
        // reading (let alone rewriting) settings.json on every launch for the
        // overwhelming majority of users who never enabled the old hook.
        guard !generated.isEmpty || currentStatuslineCommand() == wrapperCommand else { return }

        restoreOriginalCommand()
        for url in generated {
            try? fileManager.removeItem(at: url)
        }
        debugLog("[rate-limit] retired legacy statusline hook")
    }

    private static func currentStatuslineCommand() -> String? {
        guard let settings = loadSettings() else { return nil }
        return (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// Put back whatever the user had before we wrapped it. If the sidecar is
    /// gone we cannot invent a command, so the key is removed entirely — the
    /// same end state as never having configured a statusline.
    private static func restoreOriginalCommand() {
        guard var settings = loadSettings(),
              (settings["statusLine"] as? [String: Any])?["command"] as? String == wrapperCommand
        else { return }

        if let original = try? String(contentsOf: sidecarURL, encoding: .utf8),
           !original.isEmpty {
            settings["statusLine"] = ["type": "command", "command": original]
        } else {
            settings.removeValue(forKey: "statusLine")
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        // Atomic so a concurrent Claude Code read never sees a torn file.
        try? data.write(to: settingsURL, options: .atomic)
    }

    private static func loadSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
