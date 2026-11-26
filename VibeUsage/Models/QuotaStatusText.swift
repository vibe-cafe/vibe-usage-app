/// Fixed quota read messages shared by both panels and diagnostics.
enum QuotaStatusText {
    static func authorizationText(for snapshot: ProviderRateLimit, zCodeRegion: ZCodeQuotaRegion = .bigModel) -> String {
        if let failure = snapshot.liveFailure, failure != .credentialsNotFound, failure != .credentialsRejected {
            return liveFailureText(failure, provider: snapshot.provider)
        }
        let missing = snapshot.liveFailure == .credentialsNotFound
        switch snapshot.provider {
        case .zCode:
            return missing ? "请在设置中配置 \(zCodeRegion.apiKeyName)" : "API Key 无效，请在设置中更换"
        case .antigravity: return "请在 Antigravity 中登录"
        case .opencodeGo: return "请在 OpenCode 中重新登录后重试"
        case .kimiCode where missing, .cursor where missing:
            return "请先登录 \(snapshot.provider.displayName)"
        default: return missing ? "请先登录" : "登录已失效，请重新登录"
        }
    }

    /// A settled card prefers the source's empty reason, then the live read's failure.
    static func emptyStateText(for snapshot: ProviderRateLimit, isDetected: Bool) -> String {
        switch snapshot.emptyReason {
        case .limitReached:
            return "额度已用满 · 等待重置"
        case .noWindow:
            return "没有生效的额度窗口"
        case .notEntitled:
            return "未订阅 \(snapshot.provider.displayName)"
        case .sessionWithoutPlanLimits:
            // Claude Code answers `rate_limits_available: false` for a token
            // (a gateway or relay), an API key, a cloud provider, and for no
            // sign-in at all; what they share is that it is not using a
            // subscription sign-in. The subscription itself may be fine.
            return snapshot.provider == .claudeCode ? "Claude Code 未使用订阅登录" : "当前登录方式不含订阅额度"
        case .periodEnded:
            switch snapshot.provider {
            case .grok: return "账期已结束 · 用一次 Grok 后更新"
            case .antigravity: return "额度已重置 · 下次读取时更新"
            default: return "上个周期已结束"
            }
        case .noLocalRecord:
            switch snapshot.provider {
            case .grok: return "暂无记录 · 用一次 Grok 后更新"
            case .antigravity: return "用过 Antigravity 后显示"
            default: return "本机暂无记录"
            }
        case .nonessentialTrafficDisabled:
            return "组织策略关闭了 Claude Code 非必要流量 · 无法读取"
        case nil:
            // The live read's own fixed reason (e.g. no Claude Code binary)
            // is more specific than local detection, which only saw a folder.
            if let failure = snapshot.liveFailure {
                return liveFailureText(failure, provider: snapshot.provider)
            }
            if snapshot.fetchedAt == nil { return "尚未读取" }
            return isDetected ? "没读到额度，原因未知" : "未检测到安装"
        }
    }

    /// Headline and source line for a `.retryableError` card. Without a known
    /// reason (an adapter that cannot name one) the generic headline stays.
    /// Such a card only exists after a live read found nothing it could fall
    /// back to, so its source is always the live read.
    static func retryableErrorText(for snapshot: ProviderRateLimit) -> (title: String, detail: String) {
        let title = snapshot.liveFailure.map { liveFailureText($0, provider: snapshot.provider) }
            ?? "暂时读不到额度"
        // A local record that could not be read (Grok's log) is not a live read.
        switch snapshot.source {
        case .localLog: return (title, "来源：本地日志")
        case .cache: return (title, "来源：缓存")
        default: return (title, "来源：实时读取")
        }
    }

    static func sourceNote(for snapshot: ProviderRateLimit) -> String? {
        guard snapshot.status == .ok else { return nil }
        let reason = snapshot.liveFailure.map { liveFailureText($0, provider: snapshot.provider) }
        let source: String
        switch snapshot.source {
        case .live where reason != nil: source = "上次实时读取"
        case .cache: source = "缓存"
        case .desktopRecord: source = "Claude 桌面端记录"
        case .localLog: source = "本地日志"
        default: return reason
        }
        return ["来源：\(source)", reason].compactMap { $0 }.joined(separator: " · ")
    }

    /// Our own fixed copy for every reason a live read can report. Nothing
    /// here interpolates process output, server text, or a path — only the
    /// product name and an HTTP status number.
    nonisolated static func liveFailureText(
        _ failure: ProviderRateLimit.LiveFailure,
        provider: ProviderRateLimit.Provider
    ) -> String {
        switch failure {
        case .claudeBinaryNotFound: return "未找到 Claude Code"
        case .claudeLaunchFailed: return "启动失败"
        case .claudeTimedOut, .endpointTimedOut, .cliTimedOut: return "读取超时"
        case .claudeNoResponse: return "没有响应"
        case .claudeNoWindows, .programNoAnswer: return "没有返回额度"
        case .claudeBlockedByPolicy: return "组织策略关闭了 Claude Code 非必要流量"
        case .credentialsNotFound where provider == .opencodeGo: return "在 OpenCode 里登录后自动显示"
        case .credentialsNotFound where provider == .grok: return "运行 grok login 后可实时读取"
        case .credentialsNotFound: return "未找到登录信息"
        case .credentialsExpired where provider == .opencodeGo: return "打开 OpenCode 后自动显示"
        case .credentialsRejected, .credentialsExpired: return "登录已失效"
        case .credentialsUnreadable: return "读不到登录信息"
        case .credentialsEncrypted: return "登录信息已加密，暂时读不了"
        case .loginRefreshFailed: return "登录续期失败"
        case .signInRequired: return "需要登录 \(provider.displayName)"
        case .signInExpired: return "\(provider.displayName) 登录已失效"
        case .programNotFound where provider == .antigravity: return "请安装 agy 或 Antigravity"
        case .programNotFound where provider == .grok: return "未找到 Grok 命令行"
        case .programNotFound: return "未找到程序"
        case .programOutdated: return "版本较旧，升级后可实时读取"
        case .localRecordUnreadable: return "读不了本机记录"
        case .endpointUnreachable: return "连接失败"
        case let .endpointHTTPStatus(status): return status.map { "接口报错 \($0)" } ?? "接口报错"
        case .endpointUnrecognized: return "返回数据无法识别"
        case .cliRuntimeMissing: return "缺少 Node.js"
        case .cliFailed: return "配额 CLI 出错"
        case .cliUnrecognizedOutput: return "配额 CLI 输出无法识别"
        case .cliSchemaMismatch: return "配额 CLI 版本不兼容"
        case .cliNoResult: return "配额 CLI 没有返回结果"
        case .cliReportedFailure: return "实时读取失败"
        case let .egressRegionUnsupported(region): return "网络出口\(egressPlace(region))，已暂停读取"
        case .egressUnconfirmed: return "无法确认网络出口，已暂停读取"
        case .proxyNotDetected: return "未检测到代理，已暂停读取"
        case .proxyUnsupported: return "代理无法照着走，已暂停读取"
        }
    }

    /// Where an unsupported egress is, in the card's words.
    nonisolated static func egressPlace(_ region: String) -> String {
        switch region {
        case "CN": return "在中国大陆"
        case "HK": return "在香港"
        case "MO": return "在澳门"
        default: return "不在支持地区"
        }
    }
}
