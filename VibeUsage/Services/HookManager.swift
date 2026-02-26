import Foundation

/// Manages removal/restoration of vibe-usage session hooks.
/// When the Mac app is running, hooks are unnecessary (we poll instead).
enum HookManager {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let markerFile = home.appendingPathComponent(".vibe-usage/mac-app-active")
    private static let backupFile = home.appendingPathComponent(".vibe-usage/hooks-backup.json")

    // MARK: - Marker File

    /// Write marker file so CLI's ensureHooks() knows Mac app is active
    static func writeMarker() {
        let marker: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "since": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: marker, options: .prettyPrinted)
            try data.write(to: markerFile)
        } catch {
            print("Failed to write mac-app-active marker: \(error)")
        }
    }

    /// Remove marker file on quit
    static func removeMarker() {
        try? FileManager.default.removeItem(at: markerFile)
    }

    // MARK: - Hook Removal (on app start)

    /// Remove vibe-usage hooks from all supported tools and back them up
    static func removeHooks() {
        var backup: [String: Any] = [:]

        // Claude Code: ~/.claude/settings.json
        if let result = removeClaudeCodeHook() {
            backup["claude"] = result
        }

        // Codex CLI: ~/.codex/config.toml
        if let result = removeCodexHook() {
            backup["codex"] = result
        }

        // Gemini CLI: ~/.gemini/settings.json
        if let result = removeGeminiHook() {
            backup["gemini"] = result
        }

        // Save backup for restoration
        if !backup.isEmpty {
            do {
                let data = try JSONSerialization.data(withJSONObject: backup, options: .prettyPrinted)
                try data.write(to: backupFile)
            } catch {
                print("Failed to save hooks backup: \(error)")
            }
        }
    }

    // MARK: - Hook Restoration (on app quit)

    /// Restore hooks from backup using CLI's inject mechanism
    static func restoreHooks() {
        // The simplest approach: call vibe-usage to re-inject hooks
        // This ensures we use the same logic as the CLI
        guard let runtime = RuntimeDetector.detect() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.executablePath)

        // We don't have a direct "inject hooks" command, but running init
        // without changing the key would re-inject hooks.
        // For now, just remove the marker — CLI's ensureHooks() will
        // re-inject on next sync.
        removeMarker()

        // Delete backup
        try? FileManager.default.removeItem(at: backupFile)
    }

    // MARK: - Claude Code Hook

    private static func removeClaudeCodeHook() -> [String: Any]? {
        let settingsPath = home.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsPath),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any],
              var sessionEnd = hooks["SessionEnd"] as? [[String: Any]] else {
            return nil
        }

        let original = sessionEnd

        // Remove entries containing "vibe-usage"
        sessionEnd = sessionEnd.compactMap { entry in
            if let hooksList = entry["hooks"] as? [[String: Any]] {
                let filtered = hooksList.filter { hook in
                    guard let command = hook["command"] as? String else { return true }
                    return !command.contains("vibe-usage")
                }
                if filtered.isEmpty { return nil }
                var modified = entry
                modified["hooks"] = filtered
                return modified
            }
            // Old format: direct { type, command }
            if let command = entry["command"] as? String, command.contains("vibe-usage") {
                return nil
            }
            return entry
        }

        hooks["SessionEnd"] = sessionEnd
        settings["hooks"] = hooks

        do {
            let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try newData.write(to: settingsPath)
            return ["SessionEnd": original]
        } catch {
            print("Failed to update Claude Code settings: \(error)")
            return nil
        }
    }

    // MARK: - Codex Hook

    private static func removeCodexHook() -> [String: Any]? {
        let configPath = home.appendingPathComponent(".codex/config.toml")
        guard var content = try? String(contentsOf: configPath, encoding: .utf8),
              content.contains("vibe-usage") else {
            return nil
        }

        let original = content

        // Remove [notify] section containing vibe-usage
        // Simple approach: remove lines with vibe-usage from the [notify] section
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var inNotifySection = false

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "[notify]" {
                inNotifySection = true
                result.append(line)
                continue
            }
            if inNotifySection && line.hasPrefix("[") {
                inNotifySection = false
            }
            if inNotifySection && line.contains("vibe-usage") {
                continue // Skip this line
            }
            result.append(line)
        }

        content = result.joined(separator: "\n")

        do {
            try content.write(to: configPath, atomically: true, encoding: .utf8)
            return ["content": original]
        } catch {
            print("Failed to update Codex config: \(error)")
            return nil
        }
    }

    // MARK: - Gemini Hook

    private static func removeGeminiHook() -> [String: Any]? {
        let settingsPath = home.appendingPathComponent(".gemini/settings.json")
        guard let data = try? Data(contentsOf: settingsPath),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any],
              var sessionEnd = hooks["SessionEnd"] as? [[String: Any]] else {
            return nil
        }

        let original = sessionEnd

        sessionEnd = sessionEnd.filter { entry in
            guard let command = entry["command"] as? String else { return true }
            return !command.contains("vibe-usage")
        }

        hooks["SessionEnd"] = sessionEnd
        settings["hooks"] = hooks

        do {
            let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try newData.write(to: settingsPath)
            return ["SessionEnd": original]
        } catch {
            print("Failed to update Gemini settings: \(error)")
            return nil
        }
    }
}
