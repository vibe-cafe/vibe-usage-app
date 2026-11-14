import Foundation

/// Runs `vibe-usage sync` through the chosen runtime (`RuntimeDetector`) and
/// interprets the result.
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
                RuntimeDetector.unavailableMessage
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

    /// How a run ended, for the local sync history: a fixed result and reason
    /// derived from the process, never its text.
    struct Outcome: Equatable, Sendable {
        var result: SyncRecord.Result
        var reason: SyncRecord.Reason?
        var httpStatus: Int?
        var exitCode: Int32?
        var launcherStage: SyncRecord.LauncherStage?
        var cliFallback: SyncRecord.LauncherStage?
    }

    /// `outcome` is nil only when no sync actually ran (one was already in
    /// flight), so that call leaves no history entry.
    func runSync() async -> (result: Result<String, SyncError>, outcome: Outcome?) {
        guard !isRunning else {
            return (.success("同步已在进行中"), nil)
        }
        isRunning = true
        defer { isRunning = false }

        guard let runtime = await RuntimeDetector.detect() else {
            return (.failure(.noRuntime), Outcome(result: .launchFailed, reason: .runtimeMissing))
        }

        do {
            let output = try await CLIProcessRunner.run(
                executable: runtime.executablePath, arguments: runtime.arguments(["sync"]),
                environment: runtime.environment(base: ProcessInfo.processInfo.environment), timeout: 120
            )
            return (interpret(output), Self.outcome(for: output))
        } catch {
            return (
                .failure(.processFailure(error.localizedDescription)),
                Outcome(result: .launchFailed, reason: .processNotStarted)
            )
        }
    }

    /// Classifies a finished run into fixed codes. The process text is only
    /// *matched* here; nothing from it is kept except an HTTP status number.
    nonisolated static func outcome(for output: CLIProcessRunner.Output) -> Outcome {
        // Like the Windows app, a timeout keeps no fallback stage: the
        // timeout path does not judge what was printed before the kill.
        if output.timedOut { return Outcome(result: .timedOut) }
        var outcome = classify(
            stdout: output.stdout,
            stderr: CLILauncher.withoutNotice(output.stderr),
            exitCode: output.exitCode
        )
        if outcome.result != .launchFailed {
            outcome.cliFallback = CLILauncher.fallbackStage(in: output.stderr)
        }
        return outcome
    }

    /// `stderr` has had the cached-CLI notice removed.
    private nonisolated static func classify(stdout: String, stderr: String, exitCode: Int32) -> Outcome {
        if exitCode == 0 { return Outcome(result: .success) }
        if let stage = CLILauncher.failureStage(in: stderr) {
            return Outcome(result: .launchFailed, reason: .launcherFailed, launcherStage: stage)
        }

        let text = stdout + "\n" + stderr
        // The CLI prints its own Chinese hint; older builds and the app's
        // earlier check used the English markers.
        if text.contains("API Key 无效") || text.contains("Invalid API key")
            || text.contains("UNAUTHORIZED") {
            return Outcome(result: .failure, reason: .keyRejected)
        }
        // `npx` (test hooks) failing to fetch or start the package: the CLI's
        // own code never ran (e.g. the npm registry is unreachable).
        let lowered = text.lowercased()
        if lowered.contains("npm err!") || lowered.contains("npm error")
            || lowered.range(of: #"(?m)^error: .*(registry|manifest|vibe-usage)"#,
                             options: .regularExpression) != nil {
            return Outcome(result: .launchFailed, reason: .launcherFailed)
        }
        if let match = text.range(of: #"HTTP [1-5][0-9]{2}"#, options: .regularExpression),
           let status = Int(text[match].dropFirst(5)) {
            return Outcome(result: .failure, reason: .serverError, httpStatus: status)
        }
        let networkMarkers = ["ECONNREFUSED", "ENOTFOUND", "ETIMEDOUT", "ECONNRESET",
                              "EAI_AGAIN", "EHOSTUNREACH", "ENETUNREACH", "socket hang up"]
        if networkMarkers.contains(where: text.contains) {
            return Outcome(result: .failure, reason: .network)
        }
        if text.contains("RangeError: Invalid string length") || text.contains("node:internal/readline") {
            return Outcome(result: .failure, reason: .cliCrashed)
        }
        return Outcome(result: .failure, reason: .other, exitCode: exitCode)
    }

    func interpret(_ output: CLIProcessRunner.Output) -> Result<String, SyncError> {
        if output.timedOut { return .failure(.timeout) }
        let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = CLILauncher.withoutNotice(output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog("[SyncEngine] Exit: \(output.exitCode)")
        debugLog("[SyncEngine] stdout: \(stdout.prefix(500))")
        debugLog("[SyncEngine] stderr: \(stderr.prefix(500))")
        if output.exitCode == 0 {
            return .success(stdout.isEmpty ? "同步完成" : stdout)
        }
        let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        if combined.contains("Invalid API key") || combined.contains("UNAUTHORIZED") {
            return .failure(.unauthorized)
        }
        if let stage = CLILauncher.failureStage(in: stderr), let message = Self.launcherFailureText(stage) {
            return .failure(.processFailure(message))
        }
        return .failure(.processFailure(friendlyFailureMessage(combined, exitCode: output.exitCode)))
    }

    /// Our own copy for a launcher failure the footer can name; `nil` keeps
    /// the launcher's line (an unexpected error is better shown than hidden).
    nonisolated static func launcherFailureText(_ stage: SyncRecord.LauncherStage) -> String? {
        switch stage {
        case .network: "连不上 npm 源，CLI 没有下载成功"
        case .registry: "npm 源返回错误，CLI 没有下载成功"
        case .download: "CLI 下载或校验失败"
        case .install: "CLI 安装失败"
        case .other: nil
        }
    }

    private func friendlyFailureMessage(_ message: String, exitCode: Int32) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Exit code \(exitCode)" }

        if trimmed.contains("RangeError: Invalid string length")
            || trimmed.contains("node:internal/readline") {
            return "本地同步工具读取历史记录时崩溃（RangeError: Invalid string length）。请更新 @vibe-cafe/vibe-usage 后重试；订阅配额监控可在设置中单独开启或关闭。"
        }

        return trimmed
    }
}
