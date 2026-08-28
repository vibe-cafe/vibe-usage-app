import Foundation

/// Reads Claude's subscription quota by asking a Claude Code binary for it over
/// the stdio control protocol — the same `get_usage` request the Agent SDK
/// exposes as `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()`.
///
/// Why a subprocess instead of a file read or a direct HTTP call:
///
/// - **The statusline capture we used before is TUI-only.** Claude Code builds
///   the statusline payload inside its terminal render loop, so the Claude
///   Desktop app — which hosts sessions through the SDK, not the TUI — never
///   invokes the wrapper. Desktop-only users saw an empty card forever while
///   their token stats worked fine (Desktop still writes `~/.claude/projects`).
/// - **We cannot call the usage endpoint ourselves.** Claude's OAuth token
///   lives in the `Claude Code-credentials` keychain item, whose "Always Allow"
///   ACL binds to the *reading app's* code signature — every re-signed release
///   re-prompts. That path was tried and reverted in commit 87e1061.
///
/// Delegating to the binary sidesteps both: it reads its own keychain entry
/// (no prompt for us), fetches `/api/oauth/usage` itself, and hands back the
/// parsed windows. Cost is a ~2.5s short-lived process and zero tokens — the
/// probe sends no prompt, so `total_cost_usd` stays 0.
///
/// The flags below keep the probe inert: `--safe-mode` skips hooks, MCP
/// servers, plugins and CLAUDE.md; `--no-session-persistence` leaves no
/// transcript behind; `--tools ""` removes every tool. It does not bump
/// `numStartups`, and it refreshes Claude's own `cachedUsageUtilization` cache
/// as a side effect — which is exactly what `ClaudeUsageCache` paints from.
enum ClaudeUsageProbe {

    enum ProbeError: RateLimitFetchError {
        /// No Claude Code binary found in any known location.
        case noBinary
        /// Every candidate binary failed to produce a usable response.
        case allCandidatesFailed(Error)
        case launchFailed(String)
        case timedOut
        /// The process exited or closed stdout before answering.
        case noResponse
        /// `rate_limits_available: false` — API key / Bedrock / Vertex session,
        /// where plan limits genuinely do not apply.
        case limitsNotApplicable
        /// Answered, but `rate_limits` was null: the binary's own fetch of the
        /// usage endpoint failed (offline, or logged out). Distinct from
        /// `limitsNotApplicable` because here a retry can succeed.
        case limitsUnavailable

        var rateLimitFailure: RateLimitFetchFailure {
            switch self {
            case .noBinary:
                return .absent
            case .limitsNotApplicable:
                return .notApplicable
            case let .allCandidatesFailed(underlying):
                return (underlying as? any RateLimitFetchError)?.rateLimitFailure ?? .transient
            case .launchFailed, .timedOut, .noResponse, .limitsUnavailable:
                return .transient
            }
        }
    }

    /// Overall budget for one refresh, shared by every discovered binary.
    /// Measured runs land at 2.3–3.0s; a broken executable gets a smaller
    /// per-candidate slice so the next fallback can still be tried without
    /// multiplying the card's loading time by the number of installations.
    private static let timeout: TimeInterval = 25
    private static let candidateTimeout: TimeInterval = 8

    // MARK: - Entry point

    /// Try each discovered binary in order until one answers. Runs entirely off
    /// the main actor; honors task cancellation (panel closed mid-probe) by
    /// terminating the child process.
    static func fetch(now: Date = Date()) async throws -> ProviderRateLimit {
        try await fetch(candidates: discoverBinaries(), now: now, timeout: timeout)
    }

    /// Injectable entry point for lifecycle tests. `timeout` is an overall
    /// monotonic budget, not a fresh allowance for every candidate.
    static func fetch(
        candidates: [Binary],
        now: Date = Date(),
        timeout: TimeInterval
    ) async throws -> ProviderRateLimit {
        guard !candidates.isEmpty else { throw ProbeError.noBinary }

        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var lastError: Error = ProbeError.noResponse
        for candidate in candidates {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                lastError = ProbeError.timedOut
                break
            }
            do {
                let raw = try await run(
                    candidate: candidate,
                    timeout: min(candidateTimeout, remaining)
                )
                guard let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                    throw ProbeError.noResponse
                }
                if limitsAreNotApplicable(payload) {
                    throw ProbeError.limitsNotApplicable
                }
                guard let snapshot = parse(payload, now: now) else {
                    // Either `rate_limits` was null (the binary's own fetch of
                    // the usage endpoint failed — retryable) or the payload
                    // drifted. Another binary won't parse it differently, but a
                    // cache fallback still beats an error card.
                    throw ProbeError.limitsUnavailable
                }
                debugLog("[rate-limit] claude probe ok via \(candidate.label)")
                return snapshot
            } catch is CancellationError {
                throw CancellationError()
            } catch ProbeError.limitsNotApplicable {
                // Definitive answer, not a candidate failure: this account has
                // no plan limits at all. Don't retry with another binary.
                throw ProbeError.limitsNotApplicable
            } catch {
                debugLog("[rate-limit] claude probe via \(candidate.label) failed: \(error)")
                lastError = error
            }
        }
        throw ProbeError.allCandidatesFailed(lastError)
    }

    // MARK: - Binary discovery

    struct Binary: Equatable {
        var url: URL
        var kind: Kind
        /// Human-readable origin, for debug logs and the opt-in live test.
        var label: String
    }

    enum Kind: Equatable {
        /// A standalone Claude Code install the user manages.
        case cli
        /// The copy Claude Desktop ships and updates itself.
        case desktop
        case override
    }

    /// Preference order:
    ///
    /// 1. `VIBE_USAGE_CLAUDE_BIN` — escape hatch for debugging / odd installs.
    /// 2. The standard CLI install locations.
    /// 3. The copy Claude Desktop manages — reached only when no CLI is
    ///    installed, which is exactly the case this probe was added to support.
    ///    Keeping it last means machines that already have a CLI keep using it,
    ///    and the Desktop bundle stays a fallback rather than a new default.
    ///
    /// Each candidate is tried in turn by `fetch`, so a stale or broken entry
    /// costs one failed launch rather than the whole feature.
    static func discoverBinaries(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Binary] {
        var out: [Binary] = []

        func append(_ url: URL, _ kind: Kind, _ label: String) {
            guard fileManager.isExecutableFile(atPath: url.path) else { return }
            guard !out.contains(where: { $0.url == url }) else { return }
            out.append(Binary(url: url, kind: kind, label: label))
        }

        if let override = environment["VIBE_USAGE_CLAUDE_BIN"], !override.isEmpty {
            append(
                URL(fileURLWithPath: (override as NSString).expandingTildeInPath),
                .override,
                "自定义路径"
            )
        }

        let home = fileManager.homeDirectoryForCurrentUser
        append(home.appendingPathComponent(".local/bin/claude"), .cli, "Claude Code CLI")
        append(home.appendingPathComponent(".claude/local/claude"), .cli, "Claude Code CLI")
        for path in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            append(URL(fileURLWithPath: path), .cli, "Claude Code CLI")
        }

        for bundled in desktopBundledBinaries(fileManager: fileManager, home: home) {
            append(bundled.url, .desktop, bundled.label)
        }

        return out
    }

    /// Which install the next probe will actually use, or nil when Claude Code
    /// is nowhere to be found. `.desktop` means the machine has Claude Desktop
    /// but no CLI — the only case where the UI calls the source out, since
    /// otherwise it is simply the CLI the user installed themselves.
    static func primarySourceKind(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Kind? {
        discoverBinaries(fileManager: fileManager, environment: environment).first?.kind
    }

    /// Claude Desktop keeps its Claude Code copy under a version directory that
    /// changes on every app update, so the path has to be resolved by listing
    /// rather than hardcoding. Newest version wins; the older layout that put a
    /// binary directly in the app bundle is kept as a fallback.
    private static func desktopBundledBinaries(
        fileManager: FileManager,
        home: URL
    ) -> [Binary] {
        var out: [Binary] = []

        let versionsRoot = home
            .appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = (try? fileManager.contentsOfDirectory(
            at: versionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for version in versions.sorted(by: { isVersion($0.lastPathComponent, newerThan: $1.lastPathComponent) }) {
            let binary = version.appendingPathComponent("claude.app/Contents/MacOS/claude")
            if fileManager.isExecutableFile(atPath: binary.path) {
                out.append(Binary(
                    url: binary,
                    kind: .desktop,
                    label: "Claude Desktop 内置 \(version.lastPathComponent)"
                ))
                // Old Desktop-managed versions are retained for rollback, but
                // share the same account and protocol. Retrying every retained
                // copy turns one failed refresh into N sequential timeouts.
                break
            }
        }

        let legacy = URL(fileURLWithPath: "/Applications/Claude.app/Contents/Resources/bin/claude")
        if fileManager.isExecutableFile(atPath: legacy.path) {
            out.append(Binary(url: legacy, kind: .desktop, label: "Claude Desktop 内置"))
        }
        return out
    }

    /// Numeric component-wise compare so "2.1.220" sorts above "2.1.9"
    /// (a plain string sort would not).
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let l = lhs.split(separator: ".").map { Int($0) ?? -1 }
        let r = rhs.split(separator: ".").map { Int($0) ?? -1 }
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - Control protocol

    /// Launch one binary, exchange `initialize` + `get_usage`, return the raw
    /// `response` payload as JSON bytes. Stdout is consumed as an async line
    /// sequence, so cancellation does not depend on the child (or one of its
    /// descendants) closing the pipe. Bytes rather than a parsed dictionary
    /// because `[String: Any]` cannot cross an isolation boundary under strict
    /// concurrency.
    /// `--input-format stream-json` is accepted only in print mode by current
    /// Claude Code releases. Keep the process arguments testable so a future
    /// CLI flag change cannot silently turn every probe into `.noResponse`.
    static let processArguments = [
        "--print",
        "--safe-mode",
        "--no-session-persistence",
        "--strict-mcp-config",
        "--mcp-config", #"{"mcpServers":{}}"#,
        "--tools", "",
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--verbose",
    ]

    private static func run(candidate: Binary, timeout: TimeInterval) async throws -> Data {
        let process = Process()
        process.executableURL = candidate.url
        process.arguments = processArguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = childEnvironment()

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // Discard stderr rather than piping it: nothing reads it, and an
        // unread pipe that fills up would block the child mid-response.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProbeError.launchFailed(error.localizedDescription)
        }
        let control = ProcessControl()
        control.register(process)
        defer {
            control.unregister(process)
            if process.isRunning {
                process.terminate()
            }
        }

        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        return try await withTaskCancellationHandler {
            do {
                let data = try await withThrowingTaskGroup(
                    of: Data.self,
                    returning: Data.self
                ) { group in
                    group.addTask {
                        try await exchange(
                            stdin: stdin.fileHandleForWriting,
                            stdout: stdout.fileHandleForReading
                        )
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        control.stop()
                        throw ProbeError.timedOut
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else {
                        throw ProbeError.noResponse
                    }
                    return first
                }
                try Task.checkCancellation()
                return data
            } catch {
                // Preserve cancellation as the public result so `fetch` never
                // moves on to another candidate after the panel has closed.
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            control.stop()
        }
    }

    private static func exchange(stdin: FileHandle, stdout: FileHandle) async throws -> Data {
        func send(_ object: [String: Any]) throws {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            try stdin.write(contentsOf: data + Data("\n".utf8))
        }

        try send([
            "type": "control_request",
            "request_id": "vibe-init",
            "request": ["subtype": "initialize"],
        ])

        var sentUsageRequest = false
        for try await line in stdout.bytes.lines {
            try Task.checkCancellation()
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "control_response",
                  let response = object["response"] as? [String: Any]
            else { continue }

            switch response["request_id"] as? String {
            case "vibe-init" where !sentUsageRequest:
                sentUsageRequest = true
                try send([
                    "type": "control_request",
                    "request_id": "vibe-usage",
                    "request": ["subtype": "get_usage"],
                ])
            case "vibe-usage":
                // Close stdin so the binary shuts down on its own (exit 0)
                // instead of being terminated by the deferred cleanup.
                try? stdin.close()
                guard response["subtype"] as? String == "success",
                      let payload = response["response"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: payload)
                else {
                    throw ProbeError.noResponse
                }
                return data
            default:
                continue
            }
        }

        try Task.checkCancellation()
        throw ProbeError.noResponse
    }

    /// Bridges structured-concurrency cancellation to Foundation `Process`.
    /// Async pipe iteration handles the read side; this controller makes sure
    /// the immediate Claude process also receives termination promptly.
    private final class ProcessControl: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var isStopped = false

        func register(_ process: Process) {
            lock.lock()
            let shouldStop = isStopped
            if !shouldStop { self.process = process }
            lock.unlock()

            if shouldStop, process.isRunning { process.terminate() }
        }

        func unregister(_ process: Process) {
            lock.lock()
            if self.process === process { self.process = nil }
            lock.unlock()
        }

        func stop() {
            lock.lock()
            isStopped = true
            let process = self.process
            lock.unlock()

            if let process, process.isRunning { process.terminate() }
        }
    }

    /// The app inherits whatever launched it. Two classes of variables have to
    /// be scrubbed before handing the environment to the child:
    ///
    /// - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` suppresses the usage fetch
    ///   entirely, so the probe would answer with `rate_limits: null` and we'd
    ///   silently degrade to cached data forever.
    /// - The session markers Claude Code exports into its own child processes
    ///   would make the probe look like a nested session.
    ///
    /// `CLAUDE_CONFIG_DIR` is deliberately preserved: users who relocate
    /// `~/.claude` need the probe to read the same profile they use.
    private static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in [
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
            "CLAUDECODE",
            "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_SESSION_ID",
            "CLAUDE_CODE_CHILD_SESSION",
            "CLAUDE_PID",
        ] {
            env.removeValue(forKey: key)
        }
        // A GUI app launched from Finder gets a minimal PATH; the binary itself
        // is self-contained but may shell out for git metadata.
        let base = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\($0):\(base)" } ?? base
        return env
    }

    // MARK: - Response parsing

    static let fiveHourDuration: TimeInterval = 5 * 3600
    static let sevenDayDuration: TimeInterval = 7 * 86_400

    /// Map a `get_usage` response onto `ProviderRateLimit`.
    ///
    /// Throws for the two "no numbers" cases so the coordinator can tell a
    /// permanent condition (API-key session) from a retryable one (the binary
    /// could not reach the usage endpoint), and returns nil only when the
    /// payload is shaped in a way we don't recognize.
    static func parse(
        _ payload: [String: Any],
        now: Date = Date()
    ) -> ProviderRateLimit? {
        let limits = payload["rate_limits"] as? [String: Any]

        var fiveHour: RateLimitWindow?
        var sevenDay: RateLimitWindow?
        var opus: RateLimitWindow?
        var sonnet: RateLimitWindow?
        if let limits {
            fiveHour = window(limits["five_hour"], duration: fiveHourDuration, now: now)
            sevenDay = window(limits["seven_day"], duration: sevenDayDuration, now: now)
            opus = window(limits["seven_day_opus"], duration: sevenDayDuration, now: now)
            sonnet = window(limits["seven_day_sonnet"], duration: sevenDayDuration, now: now)
        }

        guard fiveHour != nil || sevenDay != nil else { return nil }

        return ProviderRateLimit(
            provider: .claudeCode,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOpus: opus,
            sevenDaySonnet: sonnet,
            extraUsage: extraUsage(limits?["extra_usage"]),
            planLabel: planLabel(payload["subscription_type"] as? String),
            status: .ok,
            fetchedAt: now,
            // The binary fetched this from the server just now, so the numbers
            // are current — no 「数据截至」 note for the live path.
            dataAsOf: now
        )
    }

    /// True when the payload proves plan limits don't apply to this account
    /// (API key, Bedrock, Vertex). Checked before `parse` so a permanent
    /// condition isn't retried against every candidate binary.
    static func limitsAreNotApplicable(_ payload: [String: Any]) -> Bool {
        payload["rate_limits_available"] as? Bool == false
    }

    /// `{ utilization: 0-100, resets_at: ISO-8601 }`. A window whose reset has
    /// already passed keeps its percentage but loses `windowDuration`, so the
    /// elapsed-time bar can't render a confidently wrong 100% — same rule the
    /// statusline reader used.
    private static func window(_ raw: Any?, duration: TimeInterval, now: Date) -> RateLimitWindow? {
        guard let dict = raw as? [String: Any],
              let utilization = number(dict["utilization"])
        else { return nil }

        let resetsAt = (dict["resets_at"] as? String).flatMap(parseISO8601)
        let resetInFuture = (resetsAt.map { $0 > now }) ?? false
        return RateLimitWindow(
            utilization: utilization,
            resetsAt: resetsAt,
            windowDuration: resetInFuture ? duration : nil
        )
    }

    /// The endpoint emits fractional seconds; `ISO8601DateFormatter` needs to be
    /// told about them, and older payloads omit them entirely.
    static func parseISO8601(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func extraUsage(_ raw: Any?) -> ExtraUsage? {
        guard let dict = raw as? [String: Any],
              let enabled = dict["is_enabled"] as? Bool
        else { return nil }
        // Credits are reported in minor units of the account currency.
        let used = number(dict["used_credits"]) ?? 0
        let limit = number(dict["monthly_limit"]) ?? 0
        return ExtraUsage(isEnabled: enabled, spend: used / 100, limit: limit / 100)
    }

    /// Percentages arrive as whole numbers (`16`) as often as fractions
    /// (`16.4`), and `as? Double` fails outright on an integer-typed value.
    /// Going through `NSNumber` accepts either without caring how the server
    /// happened to encode it.
    static func number(_ raw: Any?) -> Double? {
        (raw as? NSNumber)?.doubleValue
    }

    /// `"pro"` / `"max"` / `"team"` → the capitalization users see on the
    /// billing page, matching how Codex plan labels are formatted.
    private static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}
