import Foundation

/// What the app reads from `cli-bootstrap.mjs` (`VibeUsage/Resources`, a
/// byte-for-byte copy of the Windows app's `src-tauri/resources/`). The
/// launcher's text is only *matched* against its fixed beginnings, the same
/// way the Windows app's `sync_history.rs` does; nothing from it is stored.
enum CLILauncher {
    /// `fail()`: the launcher could not resolve, download, install or load
    /// the CLI, so the CLI never ran.
    static let failurePrefix = "vibe-usage launcher:"
    /// `fallBackToCache()`: `latest` was out of reach and the newest complete
    /// cached version ran instead. The CLI did run.
    static let noticePrefix = "vibe-usage launcher notice:"

    typealias Stage = SyncRecord.LauncherStage

    /// The stage word of the cached-CLI notice (`stage=network;`), if the run
    /// printed one. An unknown word is `.other`, so a newer launcher cannot
    /// hide that it fell back.
    static func fallbackStage(in stderr: String) -> Stage? {
        guard let rest = stderr.split(whereSeparator: \.isNewline)
            .lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix(noticePrefix) })?
            .dropFirst(noticePrefix.count)
        else { return nil }
        let value = rest.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("stage=") else { return .other }
        let word = value.dropFirst("stage=".count).prefix { $0.isASCII && $0.isLowercase }
        return Stage(rawValue: String(word)) ?? .other
    }

    /// stderr without the notice line: it is not an error, and the CLI's own
    /// failure line must still be the one that is shown and classified.
    static func withoutNotice(_ stderr: String) -> String {
        guard stderr.contains(noticePrefix) else { return stderr }
        // `\r\n` is one Character in Swift, so split on any newline.
        return stderr.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(noticePrefix) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The launcher's own failure, by the stage its fixed message names.
    static func failureStage(in stderr: String) -> Stage? {
        guard let line = stderr.split(whereSeparator: \.isNewline)
            .lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix(failurePrefix) })
        else { return nil }
        let message = line.dropFirst(failurePrefix.count).trimmingCharacters(in: .whitespaces)
        if message.hasPrefix("registry ") { return .registry }
        if message.hasPrefix("download failed") || message.hasPrefix("integrity mismatch") { return .download }
        if message.hasPrefix("could not install") || message.contains(" did not contain ") { return .install }
        // Node's fetch error and AbortSignal.timeout(): the registry was not
        // reachable at all.
        if ["fetch failed", "TimeoutError", "aborted due to timeout"].contains(where: stderr.contains) {
            return .network
        }
        return .other
    }

    // MARK: - Cache

    /// `~/.vibe-usage/cli-cache`, or under `VIBE_USAGE_CONFIG_DIR` (test hook),
    /// exactly where the launcher puts it.
    static func cacheDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let configured = environment["VIBE_USAGE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let root = configured.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibe-usage")
            : URL(fileURLWithPath: configured)
        return root.appendingPathComponent("cli-cache")
    }

    /// The newest version a previous run installed completely — the one the
    /// launcher would fall back to. A version number only.
    static func newestCachedVersion(in directory: URL = cacheDirectory()) -> String? {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
        return names
            .compactMap { name in parse(name).map { (name, $0) } }
            .sorted { isNewer($0.1, than: $1.1) }
            .first { name, _ in
                let version = directory.appendingPathComponent(name)
                return fileManager.fileExists(atPath: version.appendingPathComponent("complete").path)
                    && fileManager.fileExists(atPath: version.appendingPathComponent("package/src/index.js").path)
            }?
            .0
    }

    private typealias Version = (numbers: [Int], prerelease: String?)

    private static func parse(_ name: String) -> Version? {
        guard name.range(of: #"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
        else { return nil }
        let parts = name.split(separator: "-", maxSplits: 1)
        return (parts[0].split(separator: ".").compactMap { Int($0) }, parts.count > 1 ? String(parts[1]) : nil)
    }

    /// The launcher's order: highest number first, a release before a
    /// prerelease of the same number.
    private static func isNewer(_ a: Version, than b: Version) -> Bool {
        if a.numbers != b.numbers { return a.numbers.lexicographicallyPrecedes(b.numbers) == false }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (pa?, pb?): return pa > pb
        }
    }
}
