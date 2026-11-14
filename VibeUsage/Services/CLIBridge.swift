import Foundation

/// Shells out to `vibe-usage` CLI for config management.
/// The Mac app reads config.json directly (read-only) but all writes go through the CLI.
enum CLIBridge {
    typealias ExtraRoots = [String: [String]]

    enum CLIError: LocalizedError {
        case noRuntime
        case processFailure(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .noRuntime: RuntimeDetector.unavailableMessage
            case .processFailure(let msg): msg
            case .timeout: "CLI 操作超时"
            }
        }
    }

    // MARK: - Config Commands

    /// Set a config value: `vibe-usage config set <key> <value>`
    static func configSet(key: String, value: String) async throws {
        try await runCLI(args: ["config", "set", key, value])
    }

    /// Get a config value: `vibe-usage config get <key>`
    static func configGet(key: String) async throws -> String? {
        let output = try await runCLI(args: ["config", "get", key])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// List tool-specific additional roots as JSON.
    static func configRoots() async throws -> ExtraRoots {
        try decodeRoots(await runCLI(args: ["config", "roots"]))
    }

    static func configAddRoot(source: String, path: String) async throws {
        try await runCLI(args: ["config", "add-root", source, path])
    }

    static func configRemoveRoot(source: String, path: String) async throws {
        try await runCLI(args: ["config", "remove-root", source, path])
    }

    static func decodeRoots(_ output: String) throws -> ExtraRoots {
        guard let data = output.data(using: .utf8) else { return [:] }
        return try JSONDecoder().decode(ExtraRoots.self, from: data)
    }

    // MARK: - Private

    @discardableResult
    static func runCLI(
        args: [String],
        timeout: TimeInterval = 30,
        environmentOverrides: [String: String] = [:],
        environmentKeysToRemove: Set<String> = []
    ) async throws -> String {
        guard let runtime = await RuntimeDetector.detect() else { throw CLIError.noRuntime }
        var env = runtime.environment(base: ProcessInfo.processInfo.environment)
        // Per-call credential injection (quota fetches): drop the other
        // regions' keys first so a stale key can never leak into a request.
        environmentKeysToRemove.forEach { env.removeValue(forKey: $0) }
        env.merge(environmentOverrides) { _, overrideValue in overrideValue }
        let output = try await CLIProcessRunner.run(
            executable: runtime.executablePath,
            arguments: runtime.arguments(args),
            environment: env, timeout: timeout
        )
        if output.timedOut { throw CLIError.timeout }
        guard output.exitCode == 0 else {
            // The cached-CLI notice is not an error.
            let message = [output.stdout, CLILauncher.withoutNotice(output.stderr)]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
            throw CLIError.processFailure(message.isEmpty ? "Exit code \(output.exitCode)" : message)
        }
        return output.stdout
    }
}
