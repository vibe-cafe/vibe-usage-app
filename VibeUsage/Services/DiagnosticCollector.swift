import CFNetwork
import CryptoKit
import Foundation

/// Gathers the typed fields of `DiagnosticSummary.Input`. Runs only when the
/// user presses 「复制诊断信息」. Each helper returns a name, a boolean, a
/// version number, or a fixed template — never a path, hostname, address, or
/// environment value. The only processes it starts are `--version` checks of
/// the runtime, the CLI (20s cap), and each Claude Code candidate (5s cap).
enum DiagnosticCollector {
    static let cliVersionTimeout: TimeInterval = 20

    /// First 4 hex characters of SHA-256(hostname): tells one person's two Macs
    /// apart without showing a name like `Someones-MacBook-Pro`.
    static func deviceTag(hostname: String) -> String {
        SHA256.hash(data: Data(hostname.utf8)).prefix(2)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func hostname() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Proxy

    static func systemProxySettings() -> [String: Any]? {
        CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
    }

    /// Whether a proxy is configured and where — never its host, port, or
    /// credentials.
    static func proxy(
        systemSettings: [String: Any]?,
        environment: [String: String]
    ) -> DiagnosticSummary.Proxy {
        var proxy = DiagnosticSummary.Proxy()
        let settings = systemSettings ?? [:]
        func enabled(_ key: String) -> Bool { (settings[key] as? NSNumber)?.boolValue == true }

        var hosts: [String] = []
        for (kind, enableKey, hostKey) in [
            ("HTTP", "HTTPEnable", "HTTPProxy"),
            ("HTTPS", "HTTPSEnable", "HTTPSProxy"),
            ("SOCKS", "SOCKSEnable", "SOCKSProxy"),
        ] where enabled(enableKey) {
            proxy.systemKinds.append(kind)
            if let host = settings[hostKey] as? String { hosts.append(host) }
        }
        proxy.systemHostsAreLocal = hosts.allSatisfy(isLoopback)
        proxy.systemPAC = enabled("ProxyAutoConfigEnable")
        proxy.systemAutoDiscovery = enabled("ProxyAutoDiscoveryEnable")

        for name in DiagnosticSummary.proxyVariableNames {
            let value = environment[name] ?? environment[name.lowercased()]
            proxy.environmentVariables[name] = !(value ?? "").isEmpty
        }
        return proxy
    }

    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    // MARK: Claude settings

    /// Names (never values) of `ANTHROPIC*` / `CLAUDE*` variables the app
    /// inherited, which Claude Code also inherits. Only conventional
    /// upper-case names are listed.
    static func claudeEnvironmentNames(_ environment: [String: String]) -> [String] {
        environment.keys
            .filter { $0.hasPrefix("ANTHROPIC") || $0.hasPrefix("CLAUDE") }
            .filter { $0.range(of: #"^[A-Z0-9_]+$"#, options: .regularExpression) != nil }
            .sorted()
    }

    /// `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json` —
    /// the file whose `env` Claude Code applies after spawn (where
    /// `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` silently empties the card).
    static func claudeSettingsURL(environment: [String: String]) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
                .appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Key names of the file's `env` object, conventional names only. Values
    /// and every other part of the file are ignored.
    static func claudeSettingsEnv(at url: URL) -> DiagnosticSummary.SettingsEnv {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable
        }
        let env = root["env"] as? [String: Any] ?? [:]
        return .names(env.keys
            .filter { $0.range(of: #"^[A-Z0-9_]+$"#, options: .regularExpression) != nil }
            .sorted())
    }

    // MARK: Runtime and CLI

    static func runtime() async -> DiagnosticSummary.Runtime? {
        guard let runtime = RuntimeDetector.detect() else { return nil }
        let directory = (runtime.executablePath as NSString).deletingLastPathComponent
        var inherited = ProcessInfo.processInfo.environment
        inherited["PATH"] = directory + (inherited["PATH"].map { ":\($0)" } ?? "")
        let environment = inherited

        async let version = versionOutput(runtime.executablePath, environment: environment)
        let node = (directory as NSString).appendingPathComponent("node")
        async let nodeVersion: String? = runtime.name == "npx"
            && FileManager.default.isExecutableFile(atPath: node)
            ? versionOutput(node, environment: environment)
            : nil
        return DiagnosticSummary.Runtime(
            name: runtime.name,
            version: await version,
            nodeVersion: await nodeVersion
        )
    }

    private static func versionOutput(_ executable: String, environment: [String: String]) async -> String? {
        guard let output = try? await CLIProcessRunner.run(
            executable: executable, arguments: ["--version"],
            environment: environment, timeout: 5
        ), !output.timedOut, output.exitCode == 0 else { return nil }
        return ClaudeUsageProbe.versionNumber(in: output.stdout)
    }

    /// The CLI the app would run right now (`@latest` through the detected
    /// runtime): whether it starts, and which version it is. The CLI's sync
    /// output does not include its version, so this is the only way the app
    /// learns it.
    static func cliCheck() async -> DiagnosticSummary.CLICheck {
        do {
            let output = try await CLIBridge.runCLI(args: ["--version"], timeout: cliVersionTimeout)
            guard let version = ClaudeUsageProbe.versionNumber(in: output) else { return .failed }
            return .started(version: version)
        } catch CLIBridge.CLIError.noRuntime {
            return .runtimeMissing
        } catch CLIBridge.CLIError.timeout {
            return .timedOut(seconds: Int(cliVersionTimeout))
        } catch {
            return .failed
        }
    }

    // MARK: System

    static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static var buildKind: String {
        if AppConfig.isExternalTest { return "外测版" }
        return AppConfig.isDev ? "开发版" : "正式版"
    }
}

extension AppState {
    /// Builds the redacted summary for 「复制诊断信息」.
    func diagnosticSummary(now: Date = Date()) async -> String {
        let environment = ProcessInfo.processInfo.environment
        let discovered = ClaudeUsageProbe.discoverBinaries()

        async let runtime = DiagnosticCollector.runtime()
        async let cli = DiagnosticCollector.cliCheck()
        async let versions = ClaudeUsageProbe.versions(of: discovered)

        let quotaLines = quotaProducts.map { product in
            DiagnosticSummary.QuotaLine(
                name: product.displayName,
                text: DiagnosticSummary.quotaText(
                    snapshot: rateLimits.first { $0.provider == product.provider },
                    isSelected: isQuotaProviderSelected(product.provider),
                    isDetected: product.isDetected,
                    isRefreshing: isRateLimitRefreshing(product.provider),
                    now: now
                )
            )
        }

        let resolvedVersions = await versions
        let input = DiagnosticSummary.Input(
            generatedAt: now,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? AppConfig.version,
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知",
            buildKind: DiagnosticCollector.buildKind,
            osVersion: DiagnosticCollector.osVersion(),
            architecture: DiagnosticCollector.architecture,
            runtime: await runtime,
            cli: await cli,
            keyConfigured: isConfigured,
            deviceTag: DiagnosticCollector.deviceTag(hostname: DiagnosticCollector.hostname()),
            proxy: DiagnosticCollector.proxy(
                systemSettings: DiagnosticCollector.systemProxySettings(),
                environment: environment
            ),
            schedulerRunning: isSyncSchedulerRunning,
            syncInterval: Self.syncInterval,
            syncRecords: syncHistory.records(),
            quotaLines: quotaLines,
            claude: DiagnosticSummary.Claude(
                log: ClaudeUsageProbe.lastAttemptLog(),
                candidates: discovered.map {
                    ($0.template ?? "VIBE_USAGE_CLAUDE_BIN 指定的程序", resolvedVersions[$0.url])
                },
                pathClaudeCount: ClaudeUsageProbe.pathClaudeCount(),
                configDirSet: !(environment["CLAUDE_CONFIG_DIR"] ?? "").isEmpty,
                environmentNames: DiagnosticCollector.claudeEnvironmentNames(environment),
                settingsEnv: DiagnosticCollector.claudeSettingsEnv(
                    at: DiagnosticCollector.claudeSettingsURL(environment: environment))
            )
        )
        return DiagnosticSummary.render(input)
    }
}
