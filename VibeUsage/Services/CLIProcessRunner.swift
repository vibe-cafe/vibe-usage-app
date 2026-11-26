import Foundation

/// Runs the CLI off the UI/cooperative executor. Output goes to temporary files:
/// waiting for exit before draining a Pipe can deadlock as soon as it fills.
/// Files also let us finish when a descendant keeps an inherited output open.
///
/// Two additions for the Cursor sign-in (`CursorLogin`): `standardInput` is
/// written to the child's stdin through a pipe and then closed (the sign-in is
/// never put in the environment or argv), and `onStdoutLine` streams stdout
/// line by line from a pipe instead of a file, for commands whose output
/// carries a credential (`login cursor --json`): it never touches the disk and
/// `Output.stdout` stays empty. Returning `false` from it stops the child.
enum CLIProcessRunner {
    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let timedOut: Bool
        /// The process ended on a signal; `exitCode` is then the signal number.
        var terminatedBySignal = false
    }

    /// Tracks the live child so task cancellation can stop it, using the same
    /// SIGTERM-then-SIGKILL ladder as the deadline.
    private final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var stopRequested = false

        var wasCancelled: Bool { lock.withLock { cancelled } }

        func register(_ process: Process) -> Bool {
            let (registered, stopNow) = lock.withLock { () -> (Bool, Bool) in
                guard !cancelled else { return (false, false) }
                self.process = process
                return (true, stopRequested)
            }
            if stopNow { stop() }
            return registered
        }

        func unregister(_ process: Process) {
            lock.withLock { if self.process === process { self.process = nil } }
        }

        func cancel() {
            lock.withLock { cancelled = true }
            stop()
        }

        /// Ends the child without marking the run cancelled (the output
        /// callback asked for it; the run still returns its output).
        func stop() {
            let process = lock.withLock { () -> Process? in
                stopRequested = true
                return self.process
            }
            guard let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        standardInput: Data? = nil,
        onStdoutLine: (@Sendable (String) -> Bool)? = nil
    ) async throws -> Output {
        let control = Control()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let output = try execute(
                            executable: executable, arguments: arguments,
                            environment: environment, timeout: timeout,
                            standardInput: standardInput, onStdoutLine: onStdoutLine,
                            control: control
                        )
                        if control.wasCancelled { throw CancellationError() }
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    private final class Deadline: @unchecked Sendable {
        // Accessed exclusively on queue, including the final synchronous read.
        let queue = DispatchQueue(label: "VibeUsage.CLIProcessDeadline")
        var expired = false
    }

    private static func execute(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        standardInput: Data?,
        onStdoutLine: (@Sendable (String) -> Bool)?,
        control: Control
    ) throws -> Output {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        // F_SETNOSIGPIPE: a child that exits before reading makes the write
        // fail with EPIPE instead of raising SIGPIPE in the app.
        let inputPipe = standardInput.map { _ in ClaudeUsageProbe.makeRequestPipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let lines = onStdoutLine.map { LineStream(onLine: $0) }
        let outputPipe = lines.map { _ in Pipe() }
        process.standardOutput = outputPipe ?? stdout
        process.standardError = stderr
        if let outputPipe, let lines {
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                // At EOF the handler would keep firing with empty data.
                if data.isEmpty { handle.readabilityHandler = nil }
                if lines.receive(data) == false { control.stop() }
            }
        }
        try process.run()
        guard control.register(process) else {
            process.terminate()
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            throw CancellationError()
        }
        defer { control.unregister(process) }
        if let inputPipe, let standardInput {
            // A few KiB at most: it fits in the pipe buffer, so this never
            // waits for the child. Closing the write end is the child's EOF.
            try? inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
            try? inputPipe.fileHandleForWriting.close()
        }

        let deadline = Deadline()
        let killItem = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            deadline.expired = true
            process.terminate()
            deadline.queue.asyncAfter(deadline: .now() + 1, execute: killItem)
        }
        deadline.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        process.waitUntilExit()
        let timedOut = deadline.queue.sync {
            timeoutItem.cancel()
            killItem.cancel()
            return deadline.expired
        }
        if let outputPipe, let lines {
            // The rest of the output arrives as the pipe reaches EOF; a
            // descendant still holding it open is not waited for long.
            lines.waitForEnd(timeout: 1)
            outputPipe.fileHandleForReading.readabilityHandler = nil
        }
        return Output(
            stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self),
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            terminatedBySignal: process.terminationReason == .uncaughtSignal
        )
    }

    /// Splits streamed stdout into lines (UTF-8, `\n`), hands each complete
    /// line to the callback once, and remembers when the pipe reached EOF.
    private final class LineStream: @unchecked Sendable {
        private let lock = NSLock()
        private let ended = DispatchSemaphore(value: 0)
        private var buffer = Data()
        private var stopped = false
        private var didEnd = false
        private let onLine: @Sendable (String) -> Bool

        init(onLine: @escaping @Sendable (String) -> Bool) {
            self.onLine = onLine
        }

        /// False once the callback asked to stop the child.
        func receive(_ data: Data) -> Bool {
            var complete: [String] = []
            lock.lock()
            if data.isEmpty {
                // EOF: a last line without a newline still counts.
                if !didEnd {
                    didEnd = true
                    if !buffer.isEmpty { complete.append(String(decoding: buffer, as: UTF8.self)) }
                    buffer.removeAll()
                }
            } else {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    complete.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            let finished = data.isEmpty
            lock.unlock()
            var keepGoing = true
            for line in complete {
                lock.lock()
                let skip = stopped
                lock.unlock()
                if skip { break }
                if !onLine(line) {
                    lock.lock()
                    stopped = true
                    lock.unlock()
                    keepGoing = false
                    break
                }
            }
            if finished { ended.signal() }
            return keepGoing
        }

        func waitForEnd(timeout: TimeInterval) {
            _ = ended.wait(timeout: .now() + timeout)
        }
    }
}
