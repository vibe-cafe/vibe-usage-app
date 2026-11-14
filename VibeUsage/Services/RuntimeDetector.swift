import Foundation

/// Chooses the JavaScript runtime that runs the CLI.
///
/// Order (approved 2026-11-14, 《Mac 自带 Node 方案》§2.1): the Node.js bundled
/// at `Contents/Helpers/node`, when it passes a one-time start-up probe; then a
/// system Node.js ≥ 20 (≥ 22.5 preferred, it has `node:sqlite`); then Bun. All
/// three run the same launcher, `cli-bootstrap.mjs` — a byte-for-byte copy of
/// the Windows app's — which resolves `@vibe-cafe/vibe-usage@latest`, caches it
/// under `~/.vibe-usage/cli-cache/`, and runs the newest complete cached
/// version when `latest` is out of reach.
///
/// `defaults write ai.vibecafe.vibe-usage cliRuntimePreference system` skips
/// the bundled Node (a support switch, no UI). The integration-test hook
/// `VIBE_USAGE_CLI_PACKAGE` and the external-test build keep running a given
/// package through the system `npx`.
enum RuntimeDetector {
    // Always run the published CLI at `latest` (see AGENTS.md "CLI version
    // policy"): pinning an exact version silently rots — a pin can predate the
    // very command the app calls — and it costs users every CLI fix until the
    // next app release. Compatibility is enforced by the versioned protocols
    // the app consumes (e.g. `QuotaCLIBridge.schemaVersion`) plus actionable
    // "update the CLI" errors, never by freezing a version here. The launcher
    // resolves the same `latest` dist-tag; `scripts/check-cli.mjs` reads this.
    static let defaultPackageSpecifier = "@vibe-cafe/vibe-usage@latest"
    private static var bundledPackageSpecifier: String? {
        #if VIBE_USAGE_EXTERNAL_TEST
        Bundle.main.url(forResource: "vibe-usage-cli", withExtension: "tgz")?.path
        #else
        nil
        #endif
    }
    static var packageSpecifier: String {
        ProcessInfo.processInfo.environment["VIBE_USAGE_CLI_PACKAGE"]
            ?? bundledPackageSpecifier
            ?? defaultPackageSpecifier
    }
    private static var usesBundledPackage: Bool {
        ProcessInfo.processInfo.environment["VIBE_USAGE_CLI_PACKAGE"] == nil
            && bundledPackageSpecifier != nil
    }
    /// A given package (integration-test path or the external-test tarball)
    /// can only run through `npx`.
    private static var usesPackageHook: Bool {
        usesBundledPackage || ProcessInfo.processInfo.environment["VIBE_USAGE_CLI_PACKAGE"] != nil
    }

    enum Kind: String, Sendable {
        case bundledNode
        case systemNode
        case bun
        /// Only the test hooks above.
        case npx
    }

    struct Runtime: Equatable, Sendable {
        let kind: Kind
        let executablePath: String
        /// `cli-bootstrap.mjs`; nil only for `npx`.
        let launcherPath: String?
        /// What the runtime reported while it was being chosen, when it was asked.
        var version: String?

        /// Arguments that run `vibe-usage <command>`.
        func arguments(_ command: [String]) -> [String] {
            if let launcherPath { return [launcherPath] + command }
            return RuntimeDetector.npxArguments(
                command: command,
                packageSpecifier: RuntimeDetector.packageSpecifier,
                usesBundledPackage: RuntimeDetector.usesBundledPackage
            )
        }

        /// The CLI's environment. A system runtime's directory goes first on
        /// `PATH`, as before. The bundled Node stays off `PATH`: tools the CLI
        /// starts (for example `agy` while reading quotas) must keep finding the
        /// user's own Node, not ours.
        func environment(base: [String: String]) -> [String: String] {
            var env = base
            if kind != .bundledNode {
                let directory = (executablePath as NSString).deletingLastPathComponent
                env["PATH"] = directory + (base["PATH"].map { ":\($0)" } ?? "")
            }
            env.merge(AppConfig.cliIdentityEnvironment) { _, appValue in appValue }
            #if DEBUG
            env["VIBE_USAGE_DEV"] = "1"
            #endif
            return env
        }
    }

    static func npxArguments(
        command: [String],
        packageSpecifier: String,
        usesBundledPackage: Bool
    ) -> [String] {
        usesBundledPackage
            ? ["--yes", "--package", packageSpecifier, "vibe-usage"] + command
            : ["--yes", packageSpecifier] + command
    }

    // MARK: - Support switch

    static let preferenceKey = "cliRuntimePreference"

    /// `defaults write ai.vibecafe.vibe-usage cliRuntimePreference system`.
    static func prefersSystemRuntime(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: preferenceKey) == "system"
    }

    /// Footer / Settings copy when nothing can run the CLI.
    static var unavailableMessage: String {
        prefersSystemRuntime()
            ? "已设为用系统运行环境，但未找到 Node.js 或 Bun"
            : "自带 Node 无法启动，也未找到 Node.js 或 Bun"
    }

    // MARK: - Bundled files

    static var bundledNodePath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/node").path
    }

    /// `cli-bootstrap.mjs` inside the SwiftPM resource bundle: under
    /// `Contents/Resources` in the app, next to the executable for `swift run`.
    static var launcherScriptPath: String? {
        let bundleName = "VibeUsage_VibeUsage.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appendingPathComponent(bundleName)),
               let path = bundle.path(forResource: "cli-bootstrap", ofType: "mjs") {
                return path
            }
        }
        return nil
    }

    // MARK: - Detection

    /// The runtime to use now. The bundled Node's probe runs once per app
    /// launch; system Node versions are read each time they are needed (only
    /// when the bundled Node is skipped or unusable).
    static func detect() async -> Runtime? {
        if usesPackageHook {
            return findExecutables("npx").first.map {
                Runtime(kind: .npx, executablePath: $0, launcherPath: nil)
            }
        }
        guard let launcher = launcherScriptPath else { return nil }
        let bundled = bundledNodePath
        return await select(
            launcherPath: launcher,
            prefersSystem: prefersSystemRuntime(),
            bundledNode: { await BundledNodeProbe.shared.status(path: bundled) },
            bundledNodePath: bundled,
            systemNodes: { await systemNodeCandidates() },
            bunPath: { findExecutables("bun").first }
        )
    }

    /// The decision itself, with every probe injected (tests). Later sources
    /// are only consulted when the earlier ones cannot be used.
    static func select(
        launcherPath: String,
        prefersSystem: Bool,
        bundledNode: () async -> BundledNodeStatus,
        bundledNodePath: String,
        systemNodes: () async -> [(path: String, version: String)],
        bunPath: () -> String?
    ) async -> Runtime? {
        if !prefersSystem, case let .ok(version) = await bundledNode() {
            return Runtime(kind: .bundledNode, executablePath: bundledNodePath,
                           launcherPath: launcherPath, version: version)
        }
        let nodes = await systemNodes()
        let preferred = nodes.first { isAtLeast($0.version, 22, 5) } ?? nodes.first { isAtLeast($0.version, 20, 0) }
        if let node = preferred {
            return Runtime(kind: .systemNode, executablePath: node.path,
                           launcherPath: launcherPath, version: node.version)
        }
        if let bun = bunPath() {
            return Runtime(kind: .bun, executablePath: bun, launcherPath: launcherPath)
        }
        return nil
    }

    /// `22.19.0` ≥ 22.5? Anything unparsable is too old.
    static func isAtLeast(_ version: String, _ major: Int, _ minor: Int) -> Bool {
        let parts = version.split(separator: ".").prefix(2).map { Int($0) }
        guard parts.count == 2, let have = parts[0], let haveMinor = parts[1] else { return false }
        return have > major || (have == major && haveMinor >= minor)
    }

    /// Every distinct `node` on the search path with the version it reports.
    private static func systemNodeCandidates() async -> [(path: String, version: String)] {
        var seen = Set<String>()
        var result: [(path: String, version: String)] = []
        for path in findExecutables("node") {
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard seen.insert(resolved).inserted else { continue }
            if let version = await versionNumber(of: path) {
                result.append((path, version))
            }
        }
        return result
    }

    /// `--version` of a runtime (5s cap), as a bare number.
    static func versionNumber(of executable: String) async -> String? {
        guard let output = try? await CLIProcessRunner.run(
            executable: executable, arguments: ["--version"],
            environment: ProcessInfo.processInfo.environment, timeout: 5
        ), !output.timedOut, output.exitCode == 0 else { return nil }
        return ClaudeUsageProbe.versionNumber(in: output.stdout)
    }

    // MARK: - Search path

    /// Search common paths where node/bun might be installed
    private static let searchPaths: [String] = {
        // Start with PATH from environment
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        // Add common install locations that might not be in PATH
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(contentsOf: [
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.fnm/current/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/local/bin",
        ])

        // nvm: resolve actual version directory (nvm doesn't create a "current" symlink)
        paths.append(contentsOf: resolveNvmPaths(home: home))

        return paths
    }()

    /// Resolve nvm node bin paths by reading ~/.nvm/alias/default or scanning versions directory.
    private static func resolveNvmPaths(home: String) -> [String] {
        let nvmDir = "\(home)/.nvm"
        let versionsDir = "\(nvmDir)/versions/node"
        let fm = FileManager.default

        // 1. Try reading ~/.nvm/alias/default to find the default version
        let aliasPath = "\(nvmDir)/alias/default"
        if let alias = try? String(contentsOfFile: aliasPath, encoding: .utf8) {
            let prefix = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty, let resolved = findNvmVersion(versionsDir: versionsDir, prefix: prefix, fm: fm) {
                return ["\(versionsDir)/\(resolved)/bin"]
            }
        }

        // 2. Fallback: pick the latest installed version (highest semver directory)
        if let entries = try? fm.contentsOfDirectory(atPath: versionsDir) {
            let sorted = entries
                .filter { $0.hasPrefix("v") }
                .sorted { compareVersions($0, $1) }
            if let latest = sorted.last {
                return ["\(versionsDir)/\(latest)/bin"]
            }
        }

        return []
    }

    /// Find the best matching nvm version directory for a given prefix (e.g. "22" matches "v22.22.0").
    private static func findNvmVersion(versionsDir: String, prefix: String, fm: FileManager) -> String? {
        // Normalize: "22" → "v22", "v22" → "v22", "lts/jod" → try lts alias
        var target = prefix
        if target.hasPrefix("lts/") {
            // Read lts alias: ~/.nvm/alias/lts/<name>
            let ltsName = String(target.dropFirst(4))
            let ltsAliasPath = "\(versionsDir)/../../alias/lts/\(ltsName)"
            if let ltsVersion = try? String(contentsOfFile: ltsAliasPath, encoding: .utf8) {
                target = ltsVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return nil
            }
        }

        let vPrefix = target.hasPrefix("v") ? target : "v\(target)"

        guard let entries = try? fm.contentsOfDirectory(atPath: versionsDir) else { return nil }
        // Find all versions matching prefix, pick highest
        let matches = entries
            .filter { $0.hasPrefix(vPrefix) && ($0 == vPrefix || $0.dropFirst(vPrefix.count).first == ".") }
            .sorted { compareVersions($0, $1) }
        return matches.last
    }

    /// Compare two version strings like "v22.11.0" and "v22.22.0" for sorting (ascending).
    private static func compareVersions(_ a: String, _ b: String) -> Bool {
        let partsA = a.dropFirst().split(separator: ".").compactMap { Int($0) }
        let partsB = b.dropFirst().split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(partsA.count, partsB.count) {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va < vb }
        }
        return false
    }

    /// Every executable called `name` on the search path, in search order.
    private static func findExecutables(_ name: String) -> [String] {
        searchPaths
            .map { "\($0)/\(name)" }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Bundled Node probe

/// Whether the bundled Node can start, decided once per app launch: a Node
/// signed with the wrong entitlements is killed by the system as soon as V8
/// asks for executable memory, and every later CLI call would fail the same
/// way. Fixed reasons only (diagnostics, §2.6).
enum BundledNodeStatus: Equatable, Sendable {
    case ok(version: String)
    /// No executable file at `Contents/Helpers/node` (e.g. a `swift run` build).
    case missing
    /// The process could not be started (wrong architecture, permissions).
    case launchFailed
    /// Ended by a signal — what the system does to a JIT without its entitlement.
    case killed
    case timedOut
    /// Exited with an error or answered something unexpected.
    case failed
}

actor BundledNodeProbe {
    static let shared = BundledNodeProbe()
    static let timeout: TimeInterval = 5

    /// Enough work for V8 to compile optimized code, then the version.
    static let script = "let s=0;for(let i=0;i<2e6;i++)s+=i%7;process.stdout.write(process.version)"

    private var probes: [String: Task<BundledNodeStatus, Never>] = [:]

    /// One probe per path per launch, shared by concurrent callers — except a
    /// timeout, which is tried again on the next use: the first run of a new
    /// 240 MB executable waits for the system's one-time scan of it (2.5s
    /// measured on an M-series Mac), and once that is done the probe takes
    /// a few hundredths of a second.
    func status(path: String) async -> BundledNodeStatus {
        if let probe = probes[path] { return await probe.value }
        let probe = Task { await Self.run(path) }
        probes[path] = probe
        let status = await probe.value
        if status == .timedOut { probes[path] = nil }
        return status
    }

    static func run(_ path: String) async -> BundledNodeStatus {
        guard FileManager.default.isExecutableFile(atPath: path) else { return .missing }
        let output: CLIProcessRunner.Output
        do {
            output = try await CLIProcessRunner.run(
                executable: path, arguments: ["-e", script],
                environment: ProcessInfo.processInfo.environment, timeout: timeout
            )
        } catch {
            return .launchFailed
        }
        return classify(output)
    }

    static func classify(_ output: CLIProcessRunner.Output) -> BundledNodeStatus {
        if output.timedOut { return .timedOut }
        if output.terminatedBySignal { return .killed }
        let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.exitCode == 0, version.hasPrefix("v"),
              let number = ClaudeUsageProbe.versionNumber(in: version) else { return .failed }
        return .ok(version: number)
    }
}
