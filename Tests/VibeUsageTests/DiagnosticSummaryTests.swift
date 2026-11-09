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
        cli: DiagnosticSummary.CLICheck = .started(version: "0.14.11")
    ) -> DiagnosticSummary.Input {
        DiagnosticSummary.Input(
            generatedAt: Date(timeIntervalSince1970: 1_793_000_000),
            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!,
            appVersion: "0.7.4",
            buildNumber: "40",
            buildKind: "正式版",
            osVersion: "macOS 26.1.0",
            architecture: "arm64",
            runtime: DiagnosticSummary.Runtime(name: "bun", version: "1.2.19", nodeVersion: nil),
            cli: cli,
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
        #expect(report.contains("环境：macOS 26.1.0 arm64 · App 0.7.4（40）正式版 · 运行环境：bun 1.2.19"))
        #expect(report.contains("CLI：启动正常 · 0.14.11 · 最近一次同步：CLI 已启动"))
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
        #expect(report.contains("CLI：启动阶段失败（未找到 Node.js 或 Bun）"))

        let launch = [SyncRecord(startedAt: Date(), duration: 0, trigger: .scheduled,
                                 result: .launchFailed, reason: .runtimeMissing)]
        #expect(DiagnosticSummary.render(input(syncRecords: launch, cli: .timedOut(seconds: 20)))
            .contains("CLI：版本检查超时（20s） · 最近一次同步：CLI 启动阶段失败"))
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
            environmentNames: []
        ), now: Date(timeIntervalSince1970: 1_793_000_000))

        #expect(lines == [
            "Claude 读取记录（最近一次，2 分钟前）：",
            "  候选 1：~/.local/bin/claude · 2.1.316 · initialize 0.9s · get_usage 未完成 · Claude 配额读取超时 · 被信号 15 结束",
            "  候选 2：PATH 第 2 项中的 claude · 版本未知 · Claude 启动失败",
            "  候选 3：Claude 桌面端内置 2.1.300 · 2.1.300 · 未尝试（总时限已用完）",
            "  PATH 上的 claude：2 个 · CLAUDE_CONFIG_DIR 未设 · ANTHROPIC/CLAUDE 开头的变量（只列名字）：无",
        ])
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
}
