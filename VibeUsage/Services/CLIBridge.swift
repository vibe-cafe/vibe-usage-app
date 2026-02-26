import Foundation

/// Shells out to `vibe-usage` CLI for config management.
/// The Mac app reads config.json directly (read-only) but all writes go through the CLI.
enum CLIBridge {
    enum CLIError: LocalizedError {
        case noRuntime
        case processFailure(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .noRuntime: "未检测到 Node.js 或 Bun"
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

    // MARK: - Private

    @discardableResult
    private static func runCLI(args: [String], timeout: TimeInterval = 30) async throws -> String {
        guard let runtime = RuntimeDetector.detect() else {
            throw CLIError.noRuntime
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: runtime.executablePath)

            // Build full arguments: [runtime-specific prefix] + [@vibe-cafe/vibe-usage] + args
            var fullArgs: [String] = []
            switch runtime.name {
            case "bun":
                fullArgs = ["x", "@vibe-cafe/vibe-usage"] + args
            default:
                fullArgs = ["--yes", "@vibe-cafe/vibe-usage"] + args
            }
            process.arguments = fullArgs

            // Inherit environment with runtime dir in PATH
            var env = ProcessInfo.processInfo.environment
            let runtimeDir = (runtime.executablePath as NSString).deletingLastPathComponent
            if let existingPath = env["PATH"] {
                env["PATH"] = "\(runtimeDir):\(existingPath)"
            } else {
                env["PATH"] = runtimeDir
            }
            process.environment = env

            // In dev mode, tell CLI to use config.dev.json
            #if DEBUG
            env["VIBE_USAGE_DEV"] = "1"
            #endif

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            do {
                try process.run()
                process.waitUntilExit()
                timeoutItem.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    let msg = stderr.isEmpty ? "Exit code \(process.terminationStatus)" : stderr
                    continuation.resume(throwing: CLIError.processFailure(msg))
                }
            } catch {
                timeoutItem.cancel()
                continuation.resume(throwing: CLIError.processFailure(error.localizedDescription))
            }
        }
    }
}
