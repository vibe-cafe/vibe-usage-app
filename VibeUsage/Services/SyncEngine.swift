import Foundation

/// Executes `npx @vibe-cafe/vibe-usage sync` (or bunx) and parses the result
actor SyncEngine {
    static let shared = SyncEngine()

    enum SyncResult {
        case success(String)
        case failure(SyncError)
    }

    enum SyncError: LocalizedError {
        case noRuntime
        case unauthorized
        case processFailure(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .noRuntime:
                "未检测到 Node.js 或 Bun，请先安装"
            case .unauthorized:
                "API Key 无效，请重新配置"
            case .processFailure(let msg):
                "同步失败: \(msg)"
            case .timeout:
                "同步超时"
            }
        }
    }

    private var isRunning = false

    func runSync() async -> Result<String, SyncError> {
        guard !isRunning else {
            return .success("同步已在进行中")
        }
        isRunning = true
        defer { isRunning = false }

        guard let runtime = RuntimeDetector.detect() else {
            return .failure(.noRuntime)
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: runtime.executablePath)
            process.arguments = runtime.syncArguments

            // Inherit environment for PATH, HOME, etc.
            var env = ProcessInfo.processInfo.environment
            // Ensure the runtime's directory is in PATH
            let runtimeDir = (runtime.executablePath as NSString).deletingLastPathComponent
            if let existingPath = env["PATH"] {
                env["PATH"] = "\(runtimeDir):\(existingPath)"
            } else {
                env["PATH"] = runtimeDir
            }

            // In dev mode, tell CLI to use config.dev.json
            #if DEBUG
            env["VIBE_USAGE_DEV"] = "1"
            #endif
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Timeout after 120 seconds
            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeoutItem)

            do {
                try process.run()
                process.waitUntilExit()
                timeoutItem.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let combined = "\(stdout)\n\(stderr)"

                if process.terminationStatus == 0 {
                    // Parse success messages
                    if stdout.contains("Synced") || stdout.contains("No new usage data") {
                        continuation.resume(returning: .success(stdout))
                    } else {
                        continuation.resume(returning: .success(stdout.isEmpty ? "同步完成" : stdout))
                    }
                } else {
                    // Check for specific errors
                    if combined.contains("Invalid API key") || combined.contains("UNAUTHORIZED") {
                        continuation.resume(returning: .failure(.unauthorized))
                    } else {
                        let msg = stderr.isEmpty ? stdout : stderr
                        continuation.resume(returning: .failure(.processFailure(msg.isEmpty ? "Exit code \(process.terminationStatus)" : msg)))
                    }
                }
            } catch {
                timeoutItem.cancel()
                continuation.resume(returning: .failure(.processFailure(error.localizedDescription)))
            }
        }
    }
}
