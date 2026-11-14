import Foundation
import Testing
@testable import VibeUsage

/// Synthetic data only. Every value below is invented: no real account, key,
/// path, or host is read.
@MainActor
struct DiagnosticSummaryTests {
    // Hostile fixtures, one per redaction rule in the diagnostics plan §6.
    static let chineseHome = "/Users/张三"
    static let spacedPath = "/Users/张三/My Projects/秘密 项目/bin"
    static let encodedProjectDir = "-Users-张三-Coding-秘密项目"
    static let fakeVibeKey = "vbu_live_9f8e7d6c5b4a39281706f5e4d3c2b1a0"
    static let fakeAnthropicKey = "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
    static let fakeEmail = "zhangsan.private@example.com"
    static let fakeJWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl"
    static let proxyWithCredentials = "http://zhangsan:hunter2@proxy.corp.example:8080"
    static let fakeHostname = "张三的-MacBook-Pro"

    static let forbidden = [
        "张三", "My Projects", "秘密", "-Users-", "vbu_", "sk-ant-", "@example.com",
        "eyJ", "hunter2", "proxy.corp", "8080", "MacBook", "/Users/",
    ]

    private func expectClean(_ report: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for needle in Self.forbidden {
            #expect(!report.contains(needle), "report leaks \(needle)", sourceLocation: sourceLocation)
        }
    }

    private func input(
        quotaLines: [DiagnosticSummary.QuotaLine] = [],
        claude: DiagnosticSummary.Claude? = nil,
        syncRecords: [SyncRecord] = [],
        proxy: DiagnosticSummary.Proxy = DiagnosticSummary.Proxy(),
        cli: DiagnosticSummary.CLICheck = .started(version: "0.14.11"),
        runtime: DiagnosticSummary.Runtime? = DiagnosticSummary.Runtime(kind: .bundledNode, version: "24.22.3"),
        prefersSystemRuntime: Bool = false,
        bundledNode: BundledNodeStatus = .ok(version: "24.22.3"),
        launcherPresent: Bool = true,
        cachedCLIVersion: String? = "0.14.11"
    ) -> DiagnosticSummary.Input {
        DiagnosticSummary.Input(
            generatedAt: Date(timeIntervalSince1970: 1_793_000_000),
            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!,
            appVersion: "0.7.4",
            buildNumber: "40",
            buildKind: "正式版",
            osVersion: "macOS 26.1.0",
            architecture: "arm64",
            runtime: runtime,
            prefersSystemRuntime: prefersSystemRuntime,
            bundledNode: bundledNode,
            cli: cli,
            launcherPresent: launcherPresent,
            cachedCLIVersion: cachedCLIVersion,
            keyConfigured: true,
            deviceTag: DiagnosticCollector.deviceTag(hostname: Self.fakeHostname),
            proxy: proxy,
            schedulerRunning: true,
            syncInterval: 1800,
            syncRecords: syncRecords,
            quotaLines: quotaLines,
            claude: claude ?? DiagnosticSummary.Claude(
                log: nil, candidates: [], pathClaudeCount: 0, configDirSet: false, environmentNames: []
            )
        )
    }

    // MARK: - Redaction (§6 rule 9)

    @Test
    func redactorMasksEveryHostileValue() {
        let hostile = [
            Self.chineseHome + "/.claude/projects",
            Self.spacedPath,
            Self.encodedProjectDir + "/session.jsonl",
            Self.fakeVibeKey,
            Self.fakeAnthropicKey,
            "Authorization: Bearer abc.def.ghi",
            Self.fakeJWT,
            Self.fakeEmail,
            Self.proxyWithCredentials,
            String(repeating: "A1b2C3d4", count: 6),
        ].joined(separator: "\n")

        let redacted = DiagnosticRedactor.redact(hostile, homeDirectory: Self.chineseHome)

        for needle in Self.forbidden + ["abc.def.ghi", "A1b2C3d4A1b2"] {
            #expect(!redacted.contains(needle), "leaked \(needle)")
        }
        // The home directory still reads as `~`; what follows it is masked.
        #expect(redacted.contains("~/***"))
        #expect(redacted.contains("Bearer ***"))
    }

    @Test
    func redactorLeavesTheReportsOwnFieldsAlone() {
        let ordinary = """
        候选 1：~/.local/bin/claude · 2.1.316 · initialize 0.9s · get_usage 1.6s · 正常 · 退出码 0
        候选 2：PATH 第 3 项中的 claude · 版本未知
        账号：已配置 Key · 设备标签 7c2e · CLI：启动正常 · 0.14.11
        """
        #expect(DiagnosticRedactor.redact(ordinary, homeDirectory: Self.chineseHome) == ordinary)
    }

    /// The long-string rule must not eat the variable names the report lists
    /// on purpose (this one is exactly 40 characters), while a long mixed-case
    /// token next to it is still masked.
    @Test
    func longVariableNamesSurviveButLongTokensDoNot() {
        let line = "settings.json 的 env：CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC、ANTHROPIC_DEFAULT_SONNET_MODEL_FOR_LONG_CONTEXT_X · abcDEF0123456789abcDEF0123456789abcDEF0123"
        let redacted = DiagnosticRedactor.redact(line, homeDirectory: Self.chineseHome)
        #expect("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".count == 40)
        #expect(redacted.contains("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"))
        #expect(redacted.contains("ANTHROPIC_DEFAULT_SONNET_MODEL_FOR_LONG_CONTEXT_X"))
        #expect(!redacted.contains("abcDEF0123456789"))
        #expect(redacted.hasSuffix("· ***"))
    }

    // MARK: - Whole report

    /// Even if a hostile value slipped into a whitelisted field by mistake,
    /// the rendered report still contains none of the forbidden strings.
    @Test
    func renderedReportNeverLeaksHostileValues() {
        let claude = DiagnosticSummary.Claude(
            log: ClaudeUsageProbe.AttemptLog(
                finishedAt: Date(timeIntervalSince1970: 1_792_999_880),
                attempts: [ClaudeUsageProbe.CandidateAttempt(
                    template: Self.spacedPath + "/claude",
                    kind: .cli,
                    initializeSeconds: 0.9,
                    usageSeconds: nil,
                    outcome: .failed(.claudeTimedOut),
                    exit: .signal(15)
                )],
                untriedCount: 0
            ),
            candidates: [(Self.spacedPath + "/claude", Self.fakeAnthropicKey)],
            pathClaudeCount: 1,
            configDirSet: true,
            environmentNames: DiagnosticCollector.claudeEnvironmentNames([
                "ANTHROPIC_AUTH_TOKEN": Self.fakeAnthropicKey,
                "CLAUDE_CONFIG_DIR": Self.chineseHome + "/.claude-work",
            ])
        )
        let report = DiagnosticSummary.render(
            input(
                quotaLines: [DiagnosticSummary.QuotaLine(
                    name: "Kimi Code",
                    text: "已开启 · \(Self.fakeEmail) \(Self.fakeJWT) \(Self.encodedProjectDir) \(Self.fakeVibeKey)"
                )],
                claude: claude,
                proxy: DiagnosticCollector.proxy(
                    systemSettings: ["HTTPSEnable": 1, "HTTPSProxy": "proxy.corp.example", "HTTPSPort": 8080],
                    environment: ["https_proxy": Self.proxyWithCredentials]
                )
            ),
            homeDirectory: Self.chineseHome
        )

        expectClean(report)
        // Names survive, values do not.
        #expect(report.contains("ANTHROPIC_AUTH_TOKEN"))
        #expect(report.contains("CLAUDE_CONFIG_DIR 已设"))
        #expect(report.contains("系统代理：有（HTTPS，外部地址）"))
        #expect(report.contains("HTTPS_PROXY 有"))
        #expect(report.contains("Claude 配额读取超时"))
        #expect(report.contains("被信号 15 结束"))
        #expect(report.contains("App 进程环境中 ANTHROPIC/CLAUDE 开头的：ANTHROPIC_AUTH_TOKEN"))
    }

    @Test
    func reportCarriesTheWhitelistedFieldsInFixedLines() {
        let records = [
            SyncRecord(startedAt: Date(timeIntervalSince1970: 1_792_998_000), duration: 18.4,
                       trigger: .scheduled, result: .success),
            SyncRecord(startedAt: Date(timeIntervalSince1970: 1_792_996_200), duration: 120.2,
                       trigger: .manual, result: .timedOut),
            SyncRecord(startedAt: Date(timeIntervalSince1970: 1_792_994_400), duration: 3,
                       trigger: .launch, result: .failure, reason: .serverError, httpStatus: 502),
            SyncRecord(startedAt: Date(timeIntervalSince1970: 1_792_992_600), duration: 21,
                       trigger: .scheduled, result: .launchFailed, reason: .launcherFailed),
        ]
        let report = DiagnosticSummary.render(input(syncRecords: records), homeDirectory: Self.chineseHome)
        let lines = report.components(separatedBy: "\n")

        #expect(lines.first?.hasPrefix("Vibe Usage 诊断报告 v1 · ") == true)
        #expect(lines.first?.hasSuffix("（UTC+8）") == true)
        #expect(report.contains("环境：macOS 26.1.0 arm64 · App 0.7.4（40）正式版 · 运行环境：App 自带 Node 24.22.3"))
        #expect(lines.contains("自带 Node：能启动（24.22.3）"))
        #expect(report.contains("CLI：启动正常 · 0.14.11 · 启动脚本正常 · 本机缓存最新 0.14.11 · 最近一次同步：成功"))
        #expect(report.contains("账号：已配置 Key · 最近一次同步未被服务器拒绝 · 设备标签 "))
        #expect(report.contains("后台：App 定时同步（每 30 分钟）已开启"))
        #expect(report.contains("定时 · 成功 · 18s"))
        #expect(report.contains("手动 · 超时，120s 时被 App 结束 · 120s"))
        #expect(report.contains("启动时 · 失败（服务器错误 502） · 3.0s"))
        #expect(report.contains("定时 · CLI 启动阶段失败（下载或启动 CLI 失败） · 21s"))
        #expect(report.hasSuffix("—— 只含固定字段和错误码：不含 API Key、令牌、对话内容、项目名和任何目录名 ——"))
    }

    @Test
    func rejectedKeyAndFailedCLIAreNamed() {
        let records = [SyncRecord(startedAt: Date(), duration: 2, trigger: .manual,
                                  result: .failure, reason: .keyRejected)]
        let report = DiagnosticSummary.render(input(syncRecords: records, cli: .runtimeMissing))
        #expect(report.contains("最近一次同步被服务器拒绝（Key 无效）"))
        #expect(report.contains("CLI：启动阶段失败（没有可用的 Node.js 或 Bun） · 启动脚本正常 · 本机缓存最新 0.14.11 · 最近一次同步：失败（Key 被服务器拒绝）"))

        let launch = [SyncRecord(startedAt: Date(), duration: 0, trigger: .scheduled,
                                 result: .launchFailed, reason: .runtimeMissing)]
        #expect(DiagnosticSummary.render(input(syncRecords: launch, cli: .timedOut(seconds: 20)))
            .contains("CLI：版本检查超时（20s） · 启动脚本正常 · 本机缓存最新 0.14.11 · 最近一次同步：CLI 启动阶段失败（没有可用的 Node.js 或 Bun）"))
    }

    /// 「最近一次」 means the newest record, and only a success or an explicit
    /// rejection says anything about the Key (the wording all three clients
    /// share). An older rejection must not stand in for a newer run, and a
    /// timeout is not claimed to mean the CLI started (npx may have stalled in
    /// the package download).
    @Test
    func accountLineFollowsOnlyTheNewestRecord() {
        func record(_ result: SyncRecord.Result, _ reason: SyncRecord.Reason? = nil,
                    at time: TimeInterval = 200, status: Int? = nil) -> SyncRecord {
            SyncRecord(startedAt: Date(timeIntervalSince1970: time), duration: 3, trigger: .scheduled,
                       result: result, reason: reason, httpStatus: status)
        }
        let olderRejection = record(.failure, .keyRejected, at: 100)
        let olderSuccess = record(.success, at: 100)

        func accountLine(_ records: [SyncRecord]) -> String? {
            DiagnosticSummary.render(input(syncRecords: records))
                .components(separatedBy: "\n").first { $0.hasPrefix("账号：") }
        }

        #expect(accountLine([record(.success), olderRejection])
            == "账号：已配置 Key · 最近一次同步未被服务器拒绝 · 设备标签 \(DiagnosticCollector.deviceTag(hostname: Self.fakeHostname))")
        #expect(accountLine([record(.failure, .keyRejected), olderSuccess])?
            .contains("最近一次同步被服务器拒绝（Key 无效）") == true)

        let undecided: [SyncRecord] = [
            record(.timedOut),
            record(.launchFailed, .launcherFailed),
            record(.failure, .network),
            record(.failure, .serverError, status: 502),
            record(.failure, .other),
        ]
        for latest in undecided {
            for older in [olderRejection, olderSuccess] {
                let line = accountLine([latest, older]) ?? ""
                #expect(line.contains("无法从最近一次同步判断 Key 是否被拒"), "\(latest.result) \(String(describing: latest.reason))")
                #expect(!line.contains("被服务器拒绝"))
            }
        }

        // No record: the Key verdict is omitted.
        #expect(accountLine([])?.contains("Key 是否") == false)
        #expect(accountLine([])?.contains("服务器拒绝") == false)

        // The CLI line reuses the record's own classification.
        let expectedCLI: [(SyncRecord, String)] = [
            (record(.timedOut), "CLI：启动正常 · 0.14.11 · 启动脚本正常 · 本机缓存最新 0.14.11 · 最近一次同步：超时，120s 时被 App 结束"),
            (record(.launchFailed, .launcherFailed),
             "CLI：启动正常 · 0.14.11 · 启动脚本正常 · 本机缓存最新 0.14.11 · 最近一次同步：CLI 启动阶段失败（下载或启动 CLI 失败）"),
        ]
        for (latest, cliLine) in expectedCLI {
            let report = DiagnosticSummary.render(input(syncRecords: [latest, olderRejection]))
            #expect(report.contains(cliLine))
            #expect(!report.contains("CLI 已启动"))
        }
    }

    // MARK: - Collector helpers

    @Test
    func deviceTagIsAShortOneWayHash() {
        let tag = DiagnosticCollector.deviceTag(hostname: Self.fakeHostname)
        #expect(tag.count == 4)
        #expect(tag.allSatisfy { $0.isHexDigit })
        #expect(tag == DiagnosticCollector.deviceTag(hostname: Self.fakeHostname))
        #expect(tag != DiagnosticCollector.deviceTag(hostname: "李四的-iMac"))
    }

    @Test
    func proxyIsReportedWithoutAddressPortOrCredentials() {
        let local = DiagnosticCollector.proxy(
            systemSettings: ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPSEnable": 1, "HTTPSProxy": "localhost"],
            environment: [:]
        )
        #expect(local.systemKinds == ["HTTP", "HTTPS"])
        #expect(local.systemHostsAreLocal)
        #expect(local.environmentVariables.values.allSatisfy { !$0 })

        let pac = DiagnosticCollector.proxy(
            systemSettings: ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": Self.proxyWithCredentials],
            environment: ["ALL_PROXY": Self.proxyWithCredentials, "HTTP_PROXY": ""]
        )
        #expect(pac.systemKinds.isEmpty)
        #expect(pac.systemPAC)
        #expect(pac.environmentVariables["ALL_PROXY"] == true)
        #expect(pac.environmentVariables["HTTP_PROXY"] == false)

        let lines = DiagnosticSummary.proxyLines(pac).joined(separator: "\n")
        #expect(lines.contains("系统代理：有（自动配置脚本）"))
        #expect(lines.contains("ALL_PROXY 有"))
        #expect(lines.contains("HTTPS_PROXY、HTTP_PROXY 无"))
        expectClean(lines)
    }

    @Test
    func onlyConventionalClaudeVariableNamesAreListed() {
        let names = DiagnosticCollector.claudeEnvironmentNames([
            "ANTHROPIC_BASE_URL": "https://relay.example.com",
            "ANTHROPIC_AUTH_TOKEN": Self.fakeAnthropicKey,
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_\(Self.fakeEmail)": "x",
            "PATH": Self.spacedPath,
            "HOME": Self.chineseHome,
        ])
        #expect(names == ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK"])
    }

    // MARK: - Quota lines reuse the 1a copy

    @Test
    func quotaLinesStateSourceAndReasonInFixedCopy() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let cached = ProviderRateLimit(
            provider: .claudeCode,
            fiveHour: RateLimitWindow(utilization: 20),
            sevenDay: RateLimitWindow(utilization: 40),
            status: .ok,
            dataAsOf: now.addingTimeInterval(-30 * 3600),
            source: .cache,
            liveFailure: .claudeTimedOut
        )
        #expect(DiagnosticSummary.quotaText(snapshot: cached, isSelected: true, isDetected: true,
                                            isRefreshing: false, now: now)
            == "已开启 · 本机已检测 · 正常 · 2 个窗口 · 来源：缓存 · 数据时间：30 小时前 · 实时读取失败：Claude 配额读取超时")

        let failed = ProviderRateLimit(provider: .claudeCode, status: .retryableError,
                                       liveFailure: .claudeLaunchFailed)
        #expect(DiagnosticSummary.quotaText(snapshot: failed, isSelected: true, isDetected: true,
                                            isRefreshing: false, now: now)
            == "已开启 · 本机已检测 · Claude 启动失败 · 来源：实时读取")

        #expect(DiagnosticSummary.quotaText(snapshot: nil, isSelected: false, isDetected: false,
                                            isRefreshing: false, now: now)
            == "未开启 · 本机未检测到")
    }

    // MARK: - Claude attempt lines

    @Test
    func claudeSectionListsEachCandidateWithTimingsAndExit() {
        let log = ClaudeUsageProbe.AttemptLog(
            finishedAt: Date(timeIntervalSince1970: 1_792_999_880),
            attempts: [
                .init(template: "~/.local/bin/claude", kind: .cli, initializeSeconds: 0.9,
                      usageSeconds: nil, outcome: .failed(.claudeTimedOut), exit: .signal(15)),
                .init(template: "PATH 第 2 项中的 claude", kind: .cli, initializeSeconds: nil,
                      usageSeconds: nil, outcome: .failed(.claudeLaunchFailed), exit: nil),
            ],
            untriedCount: 1
        )
        let lines = DiagnosticSummary.claudeLines(DiagnosticSummary.Claude(
            log: log,
            candidates: [("~/.local/bin/claude", "2.1.316"), ("PATH 第 2 项中的 claude", nil),
                         ("Claude 桌面端内置 2.1.300", "2.1.300")],
            pathClaudeCount: 2,
            configDirSet: false,
            environmentNames: [],
            settingsEnv: .names(["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
        ), now: Date(timeIntervalSince1970: 1_793_000_000))

        // The historical attempts carry no version; today's versions sit in
        // their own section, so an update since then is not blamed.
        #expect(lines == [
            "Claude 读取记录（最近一次，2 分钟前）：",
            "  候选 1：~/.local/bin/claude · initialize 0.9s · get_usage 未完成 · Claude 配额读取超时 · 被信号 15 结束",
            "  候选 2：PATH 第 2 项中的 claude · Claude 启动失败",
            "  另有 1 个候选因总时限用完未尝试",
            "当前安装的 Claude Code（生成报告时检查，按查找顺序）：",
            "  1. ~/.local/bin/claude · 2.1.316",
            "  2. PATH 第 2 项中的 claude · 版本未知",
            "  3. Claude 桌面端内置 2.1.300 · 2.1.300",
            "  PATH 上的 claude：2 个 · CLAUDE_CONFIG_DIR 未设",
            "  相关变量（只列名字）：App 进程环境中 ANTHROPIC/CLAUDE 开头的：无 · settings.json 的 env：CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
        ])
    }

    /// Only the key names of `settings.json` `env` are read; values and the
    /// rest of the file never are. Synthetic files only.
    @Test
    func settingsEnvYieldsKeyNamesOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let settings: [String: Any] = [
            "env": [
                "ANTHROPIC_AUTH_TOKEN": Self.fakeAnthropicKey,
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                "HTTPS_PROXY": Self.proxyWithCredentials,
                "odd key \(Self.fakeEmail)": "x",
            ],
            "statusLine": ["command": Self.spacedPath + "/statusline.sh"],
        ]
        try JSONSerialization.data(withJSONObject: settings).write(to: url)

        let env = DiagnosticCollector.claudeSettingsEnv(at: url)
        #expect(env == .names(["ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "HTTPS_PROXY"]))

        let lines = DiagnosticSummary.claudeLines(DiagnosticSummary.Claude(
            log: nil, candidates: [], pathClaudeCount: 0, configDirSet: true,
            environmentNames: [], settingsEnv: env
        ), now: Date()).joined(separator: "\n")
        expectClean(DiagnosticRedactor.redact(lines, homeDirectory: Self.chineseHome))
        #expect(lines.contains("settings.json 的 env：ANTHROPIC_AUTH_TOKEN、CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC、HTTPS_PROXY"))

        #expect(DiagnosticCollector.claudeSettingsEnv(at: directory.appendingPathComponent("missing.json")) == .missing)
        try Data("{ not json".utf8).write(to: url)
        #expect(DiagnosticCollector.claudeSettingsEnv(at: url) == .unreadable)

        #expect(DiagnosticCollector.claudeSettingsURL(environment: ["CLAUDE_CONFIG_DIR": directory.path])
            == directory.appendingPathComponent("settings.json"))
    }

    // MARK: - Sync history

    @Test
    func syncHistoryKeepsTheTenNewestAndClears() throws {
        let suite = "DiagnosticSummaryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncHistoryStore(defaults: defaults)

        for minute in 0..<12 {
            store.append(SyncRecord(startedAt: Date(timeIntervalSince1970: TimeInterval(minute * 60)),
                                    duration: 1, trigger: .scheduled, result: .success))
        }
        let records = store.records()
        #expect(records.count == 10)
        #expect(records.first?.startedAt == Date(timeIntervalSince1970: 11 * 60))
        #expect(records.last?.startedAt == Date(timeIntervalSince1970: 2 * 60))

        store.clear()
        #expect(store.records().isEmpty)

        defaults.set(Data("not json".utf8), forKey: SyncHistoryStore.key)
        #expect(store.records().isEmpty)
    }

    /// Records hold only typed fields: encoding one never carries text from
    /// the CLI run it describes.
    @Test
    func syncRecordEncodesOnlyTypedFields() throws {
        let output = CLIProcessRunner.Output(
            stdout: "", stderr: "✗ 同步失败: HTTP 502: <html>\(Self.fakeVibeKey) \(Self.chineseHome)</html>",
            exitCode: 1, timedOut: false)
        let outcome = SyncEngine.outcome(for: output)
        let record = SyncRecord(startedAt: Date(), duration: 3, trigger: .manual, result: outcome.result,
                                reason: outcome.reason, httpStatus: outcome.httpStatus, exitCode: outcome.exitCode)
        let json = try #require(String(data: JSONEncoder().encode(record), encoding: .utf8))
        expectClean(json)
        #expect(record.reason == .serverError)
        #expect(record.httpStatus == 502)
    }

    @Test
    func syncOutcomesClassifyFromTheProcessWithoutKeepingItsText() {
        func outcome(_ stdout: String = "", _ stderr: String = "", exit: Int32 = 1,
                     timedOut: Bool = false) -> SyncEngine.Outcome {
            SyncEngine.outcome(for: .init(stdout: stdout, stderr: stderr, exitCode: exit, timedOut: timedOut))
        }

        #expect(outcome("同步完成", exit: 0) == .init(result: .success))
        #expect(outcome(timedOut: true) == .init(result: .timedOut))
        #expect(outcome("", "✗ API Key 无效，请运行 `npx @vibe-cafe/vibe-usage init` 重新配置。")
            == .init(result: .failure, reason: .keyRejected))
        #expect(outcome("", "npm error code ENOTFOUND\nnpm error network request to https://registry.npmjs.org/@vibe-cafe%2fvibe-usage failed")
            == .init(result: .launchFailed, reason: .launcherFailed))
        #expect(outcome("", "error: GET https://registry.npmjs.org/@vibe-cafe%2fvibe-usage - 404")
            == .init(result: .launchFailed, reason: .launcherFailed))
        #expect(outcome("", "✗ 同步失败: connect ECONNREFUSED 10.0.0.1:443")
            == .init(result: .failure, reason: .network))
        #expect(outcome("", "RangeError: Invalid string length")
            == .init(result: .failure, reason: .cliCrashed))
        #expect(outcome("", "something unexpected", exit: 3)
            == .init(result: .failure, reason: .other, exitCode: 3))
    }

    // MARK: - Bundled Node and the launcher (《Mac 自带 Node 方案》§2.6)

    @Test
    func runtimeLineNamesTheKindAndThePreference() {
        func line(_ runtime: DiagnosticSummary.Runtime?, prefersSystem: Bool = false) -> String {
            DiagnosticSummary.runtimeText(runtime, prefersSystem: prefersSystem)
        }
        #expect(line(.init(kind: .bundledNode, version: "24.22.3")) == "App 自带 Node 24.22.3")
        #expect(line(.init(kind: .systemNode, version: "22.19.0")) == "系统 Node 22.19.0")
        #expect(line(.init(kind: .bun, version: nil)) == "Bun（版本未知）")
        #expect(line(.init(kind: .npx, version: "10.9.3", nodeVersion: "22.19.0")) == "npx 10.9.3（Node 22.19.0）")
        #expect(line(.init(kind: .systemNode, version: "22.19.0"), prefersSystem: true)
            == "系统 Node 22.19.0（已设为优先用系统运行环境）")
        #expect(line(nil) == "自带 Node 无法启动，也未找到 Node.js 或 Bun")
        #expect(line(nil, prefersSystem: true) == "已设为优先用系统运行环境，但未找到 Node.js 或 Bun")
    }

    @Test
    func bundledNodeLineUsesFixedReasonsOnly() {
        let expected: [(BundledNodeStatus, String)] = [
            (.ok(version: "24.22.3"), "自带 Node：能启动（24.22.3）"),
            (.missing, "自带 Node：不能启动（文件缺失）"),
            (.launchFailed, "自带 Node：不能启动（无法启动）"),
            (.killed, "自带 Node：不能启动（被系统结束）"),
            (.timedOut, "自带 Node：不能启动（超时）"),
            (.failed, "自带 Node：不能启动（运行出错）"),
        ]
        for (status, text) in expected {
            let report = DiagnosticSummary.render(input(bundledNode: status))
            #expect(report.components(separatedBy: "\n").contains(text), "\(status)")
        }
    }

    @Test
    func cliLineReportsTheLauncherAndItsCache() {
        let missing = DiagnosticSummary.render(input(launcherPresent: false, cachedCLIVersion: nil))
        #expect(missing.contains("CLI：启动正常 · 0.14.11 · 启动脚本缺失 · 本机没有缓存的 CLI"))
        let cached = DiagnosticSummary.render(input(cachedCLIVersion: "0.14.12"))
        #expect(cached.contains("启动脚本正常 · 本机缓存最新 0.14.12"))
    }

    @Test
    func syncLinesNameTheLauncherStageAndTheCachedFallback() {
        func record(_ result: SyncRecord.Result, _ reason: SyncRecord.Reason? = nil,
                    stage: SyncRecord.LauncherStage? = nil,
                    fallback: SyncRecord.LauncherStage? = nil) -> SyncRecord {
            SyncRecord(startedAt: Date(), duration: 9, trigger: .scheduled, result: result,
                       reason: reason, launcherStage: stage, cliFallback: fallback)
        }
        let failures: [(SyncRecord.LauncherStage, String)] = [
            (.network, "CLI 启动阶段失败（启动脚本连不上 npm 源）"),
            (.registry, "CLI 启动阶段失败（npm 源返回错误）"),
            (.download, "CLI 启动阶段失败（下载或校验 CLI 失败）"),
            (.install, "CLI 启动阶段失败（安装 CLI 失败）"),
            (.other, "CLI 启动阶段失败（启动脚本其他错误）"),
        ]
        for (stage, text) in failures {
            #expect(DiagnosticSummary.syncResultText(record(.launchFailed, .launcherFailed, stage: stage)) == text)
        }
        let fallbacks: [(SyncRecord.LauncherStage, String)] = [
            (.network, "成功 · 用了本机缓存的 CLI（连不上 npm 源）"),
            (.registry, "成功 · 用了本机缓存的 CLI（npm 源返回错误）"),
            (.download, "成功 · 用了本机缓存的 CLI（新版下载或校验失败）"),
            (.install, "成功 · 用了本机缓存的 CLI（新版安装失败）"),
            (.other, "成功 · 用了本机缓存的 CLI（原因未知）"),
        ]
        for (stage, text) in fallbacks {
            #expect(DiagnosticSummary.syncResultText(record(.success, fallback: stage)) == text)
        }
        let report = DiagnosticSummary.render(input(syncRecords: [
            record(.failure, .serverError, fallback: .network),
        ]))
        #expect(report.contains("定时 · 失败（服务器错误 未知状态码） · 用了本机缓存的 CLI（连不上 npm 源） · 9.0s"))
    }

    /// Records written before these fields existed still load.
    @Test
    func olderSyncRecordsDecodeWithoutTheNewFields() throws {
        let old = #"[{"startedAt":800000000,"duration":3,"trigger":"manual","result":"launchFailed","reason":"launcherFailed"}]"#
        let records = try JSONDecoder().decode([SyncRecord].self, from: Data(old.utf8))
        #expect(records.first?.launcherStage == nil)
        #expect(records.first?.cliFallback == nil)
        #expect(DiagnosticSummary.syncResultText(records[0]) == "CLI 启动阶段失败（下载或启动 CLI 失败）")
    }

    /// The launcher's exact lines (`cli-bootstrap.mjs`, the Windows tests'
    /// fixtures): the notice never makes a run a failure or hides the CLI's
    /// own error, and only `vibe-usage launcher:` means the CLI never ran.
    @Test
    func launcherOutputClassifiesLikeTheWindowsApp() {
        func outcome(_ stdout: String = "", _ stderr: String = "", exit: Int32 = 1) -> SyncEngine.Outcome {
            SyncEngine.outcome(for: .init(stdout: stdout, stderr: stderr, exitCode: exit, timedOut: false))
        }
        let notice = "vibe-usage launcher notice: stage=network; running cached @vibe-cafe/vibe-usage@0.14.11 because latest is unavailable (fetch failed: ETIMEDOUT)"

        #expect(outcome("已同步 3 buckets", notice + "\n", exit: 0)
            == .init(result: .success, cliFallback: .network))
        #expect(outcome("", "  \(notice)\r\n✗ 同步失败: HTTP 502: bad gateway")
            == .init(result: .failure, reason: .serverError, httpStatus: 502, cliFallback: .network))
        // The notice's own "ETIMEDOUT" must not turn a key rejection into a network failure.
        #expect(outcome("", notice + "\n✗ API Key 无效，请重新配置")
            == .init(result: .failure, reason: .keyRejected, cliFallback: .network))
        #expect(outcome("", notice + "\nsomething unexpected", exit: 4)
            == .init(result: .failure, reason: .other, exitCode: 4, cliFallback: .network))
        for word in ["registry", "download", "install"] {
            let stderr = "vibe-usage launcher notice: stage=\(word); running cached @vibe-cafe/vibe-usage@0.14.11 because latest is unavailable (x)"
            #expect(outcome("", stderr, exit: 0).cliFallback == SyncRecord.LauncherStage(rawValue: word))
        }
        #expect(outcome("", "vibe-usage launcher notice: stage=someday; …", exit: 0).cliFallback == .other)

        let failures: [(String, SyncRecord.LauncherStage)] = [
            ("vibe-usage launcher: TypeError: fetch failed\n    at node:internal/deps/undici:1:1\n  cause: Error: connect ETIMEDOUT 104.16.0.35:443", .network),
            ("vibe-usage launcher: TimeoutError: The operation was aborted due to timeout", .network),
            ("vibe-usage launcher: registry returned 503 for @vibe-cafe/vibe-usage@latest", .registry),
            ("vibe-usage launcher: registry answered without a version/tarball for @vibe-cafe/vibe-usage@latest", .registry),
            ("vibe-usage launcher: download failed (404) for @vibe-cafe/vibe-usage@0.14.9", .download),
            ("vibe-usage launcher: integrity mismatch for @vibe-cafe/vibe-usage@0.14.9", .download),
            ("vibe-usage launcher: could not install @vibe-cafe/vibe-usage@0.14.9: EACCES", .install),
            ("vibe-usage launcher: @vibe-cafe/vibe-usage@0.14.9 did not contain src/index.js", .install),
            ("vibe-usage launcher: Error: cli failed to load", .other),
        ]
        for (stderr, stage) in failures {
            #expect(outcome("", stderr) == .init(result: .launchFailed, reason: .launcherFailed, launcherStage: stage), "\(stderr)")
        }
        // #34 on Windows: a crash inside the CLI's run() carries no prefix.
        #expect(outcome("", "Error: cli crashed\n    at run (file:///x/src/index.js:1:1)", exit: 1)
            == .init(result: .failure, reason: .other, exitCode: 1))
        // A timeout is the app's own verdict, as before.
        #expect(SyncEngine.outcome(for: .init(stdout: "", stderr: notice, exitCode: 15, timedOut: true))
            == .init(result: .timedOut))
    }
}
