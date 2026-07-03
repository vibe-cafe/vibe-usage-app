import Foundation

/// Installs a transparent wrapper into Claude Code's `statusLine.command` so we
/// can capture the `rate_limits` payload Claude Code pipes there on every render.
///
/// The wrapper (see `scripts/vibe-usage-statusline.sh`, embedded below) tees the
/// payload to `~/.vibe-usage/claude-rate-limits.json` and then re-runs the
/// user's *original* statusLine command with identical stdin, so any existing
/// HUD (e.g. claude-hud) keeps working untouched.
///
/// Install is idempotent and self-healing: `verifyAndRepair()` re-asserts the
/// wrapper if a claude-hud upgrade or `/statusline` overwrote `statusLine.command`.
enum StatuslineHook {

    enum HookError: LocalizedError {
        case settingsUnreadable(String)
        case settingsUnwritable(String)

        var errorDescription: String? {
            switch self {
            case .settingsUnreadable(let m): "无法读取 Claude 配置: \(m)"
            case .settingsUnwritable(let m): "无法写入 Claude 配置: \(m)"
            }
        }
    }

    // MARK: - Paths

    /// Honor CLAUDE_CONFIG_DIR (some users relocate ~/.claude), else default.
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
    private static var backupURL: URL { vibeDir.appendingPathComponent("settings.json.vibe-bak") }

    /// The command we install into settings.json. Quoting kept minimal: the
    /// wrapper resolves everything else from sidecar files at runtime.
    private static var wrapperCommand: String {
        "bash \"\(wrapperURL.path)\""
    }

    static var rateLimitFileURL: URL {
        vibeDir.appendingPathComponent("claude-rate-limits.json")
    }

    // MARK: - State

    /// True when settings.json currently routes the statusline through our wrapper.
    static var isInstalled: Bool {
        guard let current = currentStatuslineCommand() else { return false }
        return current == wrapperCommand
    }

    // MARK: - Install / uninstall

    /// Idempotently install (or re-assert) the wrapper. Safe to call repeatedly.
    @discardableResult
    static func install() -> Result<Void, HookError> {
        do {
            try FileManager.default.createDirectory(at: vibeDir, withIntermediateDirectories: true)
            try writeWrapperScript()

            let settings = try loadSettings()
            let existing = (settings["statusLine"] as? [String: Any])?["command"] as? String

            // Capture the user's original command into the sidecar — but never
            // capture our own wrapper (that would chain the wrapper to itself).
            if let existing, existing != wrapperCommand {
                backupSettingsIfNeeded()
                try existing.write(to: sidecarURL, atomically: true, encoding: .utf8)
                debugLog("[statusline] captured original command into sidecar")
            } else if existing == nil && !FileManager.default.fileExists(atPath: sidecarURL.path) {
                // No prior statusline at all: sidecar stays absent; wrapper emits nothing downstream.
                debugLog("[statusline] no prior statusLine.command; installing capture-only wrapper")
            }

            var newSettings = settings
            newSettings["statusLine"] = ["type": "command", "command": wrapperCommand]
            try saveSettings(newSettings)
            debugLog("[statusline] wrapper installed")
            return .success(())
        } catch let e as HookError {
            return .failure(e)
        } catch {
            return .failure(.settingsUnwritable(error.localizedDescription))
        }
    }

    /// Restore the user's original statusLine command (from the sidecar).
    @discardableResult
    static func uninstall() -> Result<Void, HookError> {
        do {
            var settings = try loadSettings()
            let current = (settings["statusLine"] as? [String: Any])?["command"] as? String
            if current == wrapperCommand {
                if let original = try? String(contentsOf: sidecarURL, encoding: .utf8),
                   !original.isEmpty {
                    settings["statusLine"] = ["type": "command", "command": original]
                } else {
                    settings.removeValue(forKey: "statusLine")
                }
                try saveSettings(settings)
            }
            removeGeneratedFiles()
            debugLog("[statusline] wrapper uninstalled")
            return .success(())
        } catch let e as HookError {
            return .failure(e)
        } catch {
            return .failure(.settingsUnwritable(error.localizedDescription))
        }
    }

    /// If the user previously enabled capture but an external tool (claude-hud
    /// upgrade, `/statusline`) replaced `statusLine.command`, silently re-wrap:
    /// the replacement becomes the new "original" we forward to. No-op if we're
    /// already installed or were never enabled.
    static func verifyAndRepair(enabled: Bool) {
        guard enabled, !isInstalled else { return }
        debugLog("[statusline] wrapper missing/clobbered — repairing")
        _ = install()
    }

    // MARK: - Helpers

    private static func currentStatuslineCommand() -> String? {
        guard let settings = try? loadSettings() else { return nil }
        return (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    private static func loadSettings() throws -> [String: Any] {
        let path = settingsURL
        guard FileManager.default.fileExists(atPath: path.path) else {
            return [:] // No settings file yet — start fresh.
        }
        do {
            let data = try Data(contentsOf: path)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HookError.settingsUnreadable("settings.json is not a JSON object")
            }
            return obj
        } catch let e as HookError {
            throw e
        } catch {
            throw HookError.settingsUnreadable(error.localizedDescription)
        }
    }

    private static func saveSettings(_ obj: [String: Any]) throws {
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            // Atomic write so a concurrent Claude Code read never sees a torn file.
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            throw HookError.settingsUnwritable(error.localizedDescription)
        }
    }

    /// One-time safety copy of the user's settings.json before our first edit.
    private static func backupSettingsIfNeeded() {
        guard !FileManager.default.fileExists(atPath: backupURL.path),
              FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        debugLog("[statusline] backed up settings.json -> \(backupURL.path)")
    }

    private static func removeGeneratedFiles() {
        for url in [wrapperURL, sidecarURL, rateLimitFileURL, backupURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func writeWrapperScript() throws {
        try wrapperScriptBody.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path
        )
    }

    /// Embedded copy of `scripts/vibe-usage-statusline.sh`. Kept in sync with
    /// that file (the repo copy is the reviewable source of truth).
    private static let wrapperScriptBody = #"""
    #!/bin/bash
    # vibe-usage statusline wrapper — generated by Vibe Usage.app. Do not edit;
    # overwritten on next install/repair. Source: scripts/vibe-usage-statusline.sh
    set -euo pipefail

    VIBE_DIR="${HOME}/.vibe-usage"
    OUT="${VIBE_DIR}/claude-rate-limits.json"
    SIDECAR="${VIBE_DIR}/statusline-original"

    payload="$(cat)"

    emit() {
      local tmp
      tmp="$(mktemp "${VIBE_DIR}/.claude-rate-limits.XXXXXX")" || return 0
      printf '%s' "$1" > "$tmp" 2>/dev/null && mv -f "$tmp" "$OUT" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    }

    mkdir -p "$VIBE_DIR" 2>/dev/null || true

    JS='
    let raw = "";
    process.stdin.on("data", d => raw += d);
    process.stdin.on("end", () => {
      try {
        const o = JSON.parse(raw);
        const rl = o && o.rate_limits;
        if (!rl || (rl.five_hour == null && rl.seven_day == null)) { process.exit(2); }
        const out = {
          five_hour: rl.five_hour ?? null,
          seven_day: rl.seven_day ?? null,
          model_id: (o.model && o.model.id) || null,
          captured_at: Math.floor(Date.now() / 1000),
        };
        process.stdout.write(JSON.stringify(out));
        process.exit(0);
      } catch (e) { process.exit(3); }
    });
    '

    RUNTIME=""
    if command -v bun >/dev/null 2>&1; then
      RUNTIME="bun"
    elif command -v node >/dev/null 2>&1; then
      RUNTIME="node"
    fi

    if [ -n "$RUNTIME" ]; then
      if parsed="$(printf '%s' "$payload" | "$RUNTIME" -e "$JS" 2>/dev/null)"; then
        [ -n "$parsed" ] && emit "$parsed"
      fi
    fi

    if [ -s "$SIDECAR" ]; then
      ORIGINAL="$(cat "$SIDECAR")"
      printf '%s' "$payload" | exec sh -c "$ORIGINAL"
    fi

    exit 0
    """#
}
