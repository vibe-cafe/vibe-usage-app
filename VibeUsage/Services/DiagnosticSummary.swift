import Foundation

/// The 「复制诊断信息」 summary: plain text a user can paste into a support
/// chat. Approved 2026-11-09 under the Architecture Approval Gate (diagnostics
/// plan, revision 2, step 1b).
///
/// Whitelist only: every line is built from the typed fields of `Input` and
/// our own fixed copy. No raw process output, server body, path, hostname,
/// account handle, key, or environment-variable value can enter `Input`, and
/// `DiagnosticRedactor` scans the result once more before it is shown or
/// copied. Nothing here is uploaded: the user decides whether to paste it.
enum DiagnosticSummary {
    static let formatVersion = 1

    struct Input {
        var generatedAt: Date
        var timeZone: TimeZone = .current
        var appVersion: String
        var buildNumber: String
        /// 正式版 / 外测版 / 开发版
        var buildKind: String
        var osVersion: String
        var architecture: String
        var runtime: Runtime?
        var cli: CLICheck
        var keyConfigured: Bool
        /// 4 hex characters of a one-way hash of the hostname.
        var deviceTag: String
        var proxy: Proxy
        var schedulerRunning: Bool
        var syncInterval: TimeInterval
        /// Newest first.
        var syncRecords: [SyncRecord]
        /// One fixed-copy line per quota product, in strip order.
        var quotaLines: [QuotaLine]
        var claude: Claude
    }

    struct Runtime: Equatable {
        /// "bun" or "npx"
        var name: String
        var version: String?
        /// For npx: the Node.js next to it.
        var nodeVersion: String?
    }

    enum CLICheck: Equatable {
        case started(version: String)
        case runtimeMissing
        case timedOut(seconds: Int)
        case failed
    }

    struct Proxy: Equatable {
        /// Manual proxy kinds switched on in System Settings (HTTP / HTTPS / SOCKS).
        var systemKinds: [String] = []
        /// All manual proxy hosts are loopback addresses (a local proxy app).
        var systemHostsAreLocal = true
        var systemPAC = false
        var systemAutoDiscovery = false
        /// `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` present in the app's own
        /// environment (either case). Names only, never values.
        var environmentVariables: [String: Bool] = [:]
    }

    struct QuotaLine: Equatable {
        var name: String
        var text: String
    }

    struct Claude {
        /// The latest completed probe. It carries no version: what is
        /// installed now may differ (Claude Code updates itself often).
        var log: ClaudeUsageProbe.AttemptLog?
        /// Current discovery, in probe order, with `claude --version` run
        /// when the summary is built.
        var candidates: [(template: String, version: String?)]
        var pathClaudeCount: Int
        var configDirSet: Bool
        /// Names of `ANTHROPIC*` / `CLAUDE*` variables in the app's environment.
        var environmentNames: [String]
        /// Key names of Claude's `settings.json` `env` (never values).
        var settingsEnv: SettingsEnv = .missing
    }

    enum SettingsEnv: Equatable {
        case names([String])
        case missing
        case unreadable
    }

    static let proxyVariableNames = ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"]

    // MARK: - Rendering

    static func render(_ input: Input, homeDirectory: String = NSHomeDirectory()) -> String {
        var lines: [String] = []
        lines.append("Vibe Usage 诊断报告 v\(formatVersion) · \(timestamp(input.generatedAt, input.timeZone))")

        var environment = "环境：\(input.osVersion) \(input.architecture) · App \(input.appVersion)（\(input.buildNumber)）\(input.buildKind)"
        environment += " · 运行环境：\(runtimeText(input.runtime))"
        lines.append(environment)
        lines.append("CLI：\(cliText(input.cli, records: input.syncRecords))")
        lines.append("账号：\(accountText(input))")
        lines.append(contentsOf: proxyLines(input.proxy))
        lines.append(input.schedulerRunning
            ? "后台：App 定时同步（每 \(Int(input.syncInterval / 60)) 分钟）已开启"
            : "后台：App 定时同步未开启（尚未配置 Key）")

        lines.append("最近同步（新的在前）：")
        if input.syncRecords.isEmpty {
            lines.append("  暂无记录")
        } else {
            lines.append(contentsOf: input.syncRecords.map {
                "  \(shortTimestamp($0.startedAt, input.timeZone)) \(syncLine($0))"
            })
        }

        lines.append("订阅配额：")
        lines.append(contentsOf: input.quotaLines.map { "  \($0.name)：\($0.text)" })

        lines.append(contentsOf: claudeLines(input.claude, now: input.generatedAt))
        lines.append("—— 只含固定字段和错误码：不含 API Key、令牌、对话内容、项目名和任何目录名 ——")
        return DiagnosticRedactor.redact(lines.joined(separator: "\n"), homeDirectory: homeDirectory)
    }

    // MARK: - Sections

    static func runtimeText(_ runtime: Runtime?) -> String {
        guard let runtime else { return "未找到 Node.js 或 Bun" }
        var text = runtime.name + (runtime.version.map { " \($0)" } ?? "（版本未知）")
        if let node = runtime.nodeVersion { text += "（Node \(node)）" }
        return text
    }

    static func cliText(_ check: CLICheck, records: [SyncRecord]) -> String {
        var text: String
        switch check {
        case let .started(version): text = "启动正常 · \(version)"
        case .runtimeMissing: text = "启动阶段失败（未找到 Node.js 或 Bun）"
        case let .timedOut(seconds): text = "版本检查超时（\(seconds)s）"
        case .failed: text = "启动阶段失败（版本检查没有成功）"
        }
        // The newest record's own classification, without inferring a stage:
        // a timeout may have stalled in the package download before the CLI
        // itself ran.
        if let last = records.first {
            text += " · 最近一次同步：\(syncResultText(last))"
        }
        return text
    }

    static func accountText(_ input: Input) -> String {
        var parts = [input.keyConfigured ? "已配置 Key" : "未配置 Key"]
        // Only the newest record speaks for 「最近一次」, and only two outcomes
        // say anything about the Key: a success (accepted) and an explicit
        // rejection. A timeout, launch failure, network or server error says
        // nothing either way. Same wording on CLI, Mac and Windows.
        if let last = input.syncRecords.first {
            if last.result == .success {
                parts.append("最近一次同步未被服务器拒绝")
            } else if last.reason == .keyRejected {
                parts.append("最近一次同步被服务器拒绝（Key 无效）")
            } else {
                parts.append("无法从最近一次同步判断 Key 是否被拒")
            }
        }
        parts.append("设备标签 \(input.deviceTag)")
        return parts.joined(separator: " · ")
    }

    static func proxyLines(_ proxy: Proxy) -> [String] {
        var system: String
        if !proxy.systemKinds.isEmpty {
            system = "有（\(proxy.systemKinds.joined(separator: "、"))，\(proxy.systemHostsAreLocal ? "本机地址" : "外部地址")）"
        } else if proxy.systemPAC {
            system = "有（自动配置脚本）"
        } else if proxy.systemAutoDiscovery {
            system = "有（自动发现）"
        } else {
            system = "无"
        }
        if system != "无" { system += " · App 不转交给 CLI 和 Claude 读取" }

        let present = proxyVariableNames.filter { proxy.environmentVariables[$0] == true }
        let absent = proxyVariableNames.filter { proxy.environmentVariables[$0] != true }
        var variables: [String] = []
        if !present.isEmpty { variables.append("\(present.joined(separator: "、")) 有") }
        if !absent.isEmpty { variables.append("\(absent.joined(separator: "、")) 无") }
        var variableLine = "      代理变量（App 进程环境）：\(variables.joined(separator: " · "))"
        if !present.isEmpty { variableLine += " · 会传给 CLI 和 Claude 读取" }
        return ["网络：系统代理：\(system)", variableLine]
    }

    static func syncLine(_ record: SyncRecord) -> String {
        let trigger: String
        switch record.trigger {
        case .scheduled: trigger = "定时"
        case .launch: trigger = "启动时"
        case .manual: trigger = "手动"
        }
        return "\(trigger) · \(syncResultText(record)) · \(seconds(record.duration))"
    }

    static func syncResultText(_ record: SyncRecord) -> String {
        switch record.result {
        case .success: return "成功"
        case .timedOut: return "超时，120s 时被 App 结束"
        case .failure: return "失败（\(syncReasonText(record))）"
        case .launchFailed: return "CLI 启动阶段失败（\(syncReasonText(record))）"
        }
    }

    static func syncReasonText(_ record: SyncRecord) -> String {
        switch record.reason {
        case .runtimeMissing: return "未找到 Node.js 或 Bun"
        case .processNotStarted: return "运行环境无法启动"
        case .launcherFailed: return "下载或启动 CLI 失败"
        case .keyRejected: return "Key 被服务器拒绝"
        case .serverError: return "服务器错误 \(record.httpStatus.map(String.init) ?? "未知状态码")"
        case .network: return "网络连接失败"
        case .cliCrashed: return "CLI 读取历史记录时崩溃"
        case .other: return "退出码 \(record.exitCode.map(String.init) ?? "未知")"
        case nil: return "原因未知"
        }
    }

    static func claudeLines(_ claude: Claude, now: Date) -> [String] {
        var lines: [String] = []
        if let log = claude.log {
            lines.append("Claude 读取记录（最近一次，\(age(from: log.finishedAt, to: now))）：")
            if log.attempts.isEmpty {
                lines.append("  当时未找到 Claude Code 程序")
            }
            for (index, attempt) in log.attempts.enumerated() {
                lines.append("  候选 \(index + 1)：\(attemptText(attempt))")
            }
            if log.untriedCount > 0 {
                lines.append("  另有 \(log.untriedCount) 个候选因总时限用完未尝试")
            }
        } else {
            lines.append("Claude 读取记录：本次启动后还没有读取过")
        }

        lines.append("当前安装的 Claude Code（生成报告时检查，按查找顺序）：")
        if claude.candidates.isEmpty {
            lines.append("  未找到 Claude Code 程序")
        }
        for (index, candidate) in claude.candidates.enumerated() {
            lines.append("  \(index + 1). \(candidate.template) · \(candidate.version ?? "版本未知")")
        }
        lines.append("  PATH 上的 claude：\(claude.pathClaudeCount) 个 · CLAUDE_CONFIG_DIR \(claude.configDirSet ? "已设" : "未设")")

        let processNames = claude.environmentNames.isEmpty ? "无" : claude.environmentNames.joined(separator: "、")
        let settingsNames: String
        switch claude.settingsEnv {
        case let .names(names): settingsNames = names.isEmpty ? "无" : names.joined(separator: "、")
        case .missing: settingsNames = "文件不存在"
        case .unreadable: settingsNames = "无法解析"
        }
        lines.append("  相关变量（只列名字）：App 进程环境中 ANTHROPIC/CLAUDE 开头的：\(processNames) · settings.json 的 env：\(settingsNames)")
        return lines
    }

    /// One historical attempt. No version: the binary may have been updated
    /// since, and today's version must not be pinned on yesterday's failure.
    static func attemptText(_ attempt: ClaudeUsageProbe.CandidateAttempt) -> String {
        var parts = [attempt.template]
        if attempt.outcome == .failed(.claudeLaunchFailed) {
            parts.append("Claude 启动失败")
            return parts.joined(separator: " · ")
        }
        parts.append("initialize " + (attempt.initializeSeconds.map(seconds) ?? "未完成"))
        parts.append("get_usage " + (attempt.usageSeconds.map(seconds) ?? "未完成"))
        switch attempt.outcome {
        case .ok: parts.append("正常")
        case .notApplicable: parts.append("账号没有订阅额度（API Key / Bedrock / Vertex）")
        case let .failed(reason): parts.append(RateLimitCardView.liveFailureText(reason, provider: .claudeCode))
        case .pending: parts.append("未结束")
        }
        switch attempt.exit {
        case let .code(code)?: parts.append("退出码 \(code)")
        case let .signal(signal)?: parts.append("被信号 \(signal) 结束")
        case nil: parts.append("进程未退出")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Quota cards

    /// One card's state in the same fixed copy the card itself shows.
    @MainActor
    static func quotaText(
        snapshot: ProviderRateLimit?,
        isSelected: Bool,
        isDetected: Bool,
        isRefreshing: Bool,
        now: Date
    ) -> String {
        let detection = isDetected ? "本机已检测" : "本机未检测到"
        guard isSelected else { return "未开启 · \(detection)" }
        var parts = ["已开启", detection]
        guard let snapshot else {
            parts.append("尚未读取")
            return parts.joined(separator: " · ")
        }
        switch snapshot.status {
        case .ok:
            let windows = snapshot.meters.count + [snapshot.fiveHour, snapshot.sevenDay,
                snapshot.sevenDayOpus, snapshot.sevenDaySonnet].compactMap { $0 }.count
            parts.append("正常 · \(windows) 个窗口")
            if let source = snapshot.source { parts.append("来源：\(sourceText(source, failed: snapshot.liveFailure != nil))") }
            if let dataAsOf = snapshot.dataAsOf { parts.append("数据时间：\(age(from: dataAsOf, to: now))") }
            if let failure = snapshot.liveFailure {
                parts.append("实时读取失败：\(RateLimitCardView.liveFailureText(failure, provider: snapshot.provider))")
            }
        case .noData:
            // Same as the card: a refresh in flight reads as loading.
            if isRefreshing {
                parts.append("正在读取")
                return parts.joined(separator: " · ")
            }
            parts.append(RateLimitCardView.emptyStateText(for: snapshot, isDetected: isDetected))
        case .retryableError:
            let text = RateLimitCardView.retryableErrorText(for: snapshot)
            parts.append(text.title)
            parts.append(text.detail)
        case .unauthorized:
            parts.append("需要重新登录")
        case .disabled:
            parts.append("未启用")
        case .error:
            parts.append("无法识别本地配额状态")
        }
        if isRefreshing { parts.append("正在刷新") }
        return parts.joined(separator: " · ")
    }

    static func sourceText(_ source: ProviderRateLimit.Source, failed: Bool) -> String {
        switch source {
        case .live: return failed ? "上次实时读取" : "实时读取"
        case .cache: return "缓存"
        case .desktopRecord: return "Claude 桌面端记录"
        case .localLog: return "本地日志"
        }
    }

    // MARK: - Formatting

    static func seconds(_ value: TimeInterval) -> String {
        value < 10 ? String(format: "%.1fs", value) : "\(Int(value.rounded()))s"
    }

    static func age(from date: Date, to now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        switch elapsed {
        case ..<60: return "刚刚"
        case ..<3600: return "\(Int(elapsed / 60)) 分钟前"
        case ..<172_800: return "\(Int(elapsed / 3600)) 小时前"
        default: return "\(Int(elapsed / 86_400)) 天前"
        }
    }

    static func timestamp(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let offset = timeZone.secondsFromGMT(for: date)
        let hours = offset / 3600
        let minutes = abs(offset % 3600) / 60
        let zone = "UTC" + (hours >= 0 ? "+" : "") + "\(hours)" + (minutes > 0 ? String(format: ":%02d", minutes) : "")
        return "\(formatter.string(from: date))（\(zone)）"
    }

    static func shortTimestamp(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
