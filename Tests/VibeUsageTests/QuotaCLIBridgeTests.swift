import Foundation
import Testing
@testable import VibeUsage

struct QuotaCLIBridgeTests {
    private func snapshot(
        _ provider: ProviderRateLimit.Provider, status: String, source: String = "live",
        fields: [String: Any] = [:]
    ) throws -> ProviderRateLimit {
        var product = fields
        product["id"] = provider.rawValue
        product["status"] = status
        product["source"] = source
        product["fetchedAt"] = "2026-11-20T00:00:00Z"
        product["meters"] = status == "ok" ? [["id": "weekly", "label": "7d", "utilization": 30]] : []
        product["message"] = "private fixture"
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "products": [product]])
        let envelope = try QuotaCLIBridge.decode(String(decoding: data, as: UTF8.self))
        return try #require(QuotaCLIBridge.snapshots(from: envelope).first)
    }

    private func settings(_ snapshot: ProviderRateLimit, keyConfigured: Bool = false) -> String {
        SettingsQuotaStatus.status(
            for: QuotaProduct(provider: snapshot.provider, availability: .ready, isDetected: true),
            zCodeKeyConfigured: keyConfigured, warningSnapshot: snapshot
        ).text
    }

    @Test @MainActor
    func signInStatusesDistinguishMissingFromRejectedForEveryCLIProduct() throws {
        let cases: [(ProviderRateLimit.Provider, String, String, String, String)] = [
            (.kimiCode, "请先登录 Kimi Code", "需登录", "登录已失效，请重新登录", "已失效"),
            (.cursor, "请先登录 Cursor", "需登录", "登录已失效，请重新登录", "已失效"),
            (.zCode, "请在设置中配置 BigModel API Key", "需 Key", "API Key 无效，请在设置中更换", "Key 无效"),
            (.antigravity, "请安装 agy 或 Antigravity", "未安装", "请在 Antigravity 中登录", "已失效"),
            (.grok, "请先登录", "需登录", "登录已失效，请重新登录", "已失效"),
        ]
        for (provider, missing, missingStatus, rejected, rejectedStatus) in cases {
            for code in ["missing_credentials", "unauthorized", "expired_credentials"] {
                let result = try snapshot(provider, status: code)
                let isMissing = code == "missing_credentials"
                #expect(result.status == .unauthorized)
                #expect(RateLimitCardView.authorizationText(for: result) == (isMissing ? missing : rejected))
                #expect(settings(result, keyConfigured: isMissing) == (isMissing ? missingStatus : rejectedStatus))
            }
        }
        let zAI = try snapshot(.zCode, status: "missing_credentials")
        #expect(RateLimitCardView.authorizationText(for: zAI, zCodeRegion: .zAI) == "请在设置中配置 Z.ai API Key")
        let agy = try snapshot(.antigravity, status: "missing_credentials", fields: ["failureReason": "programNotFound"])
        #expect(agy.liveFailure == .programNotFound)
        #expect(DiagnosticSummary.quotaText(snapshot: agy, isSelected: true, isDetected: true,
            isRefreshing: false, now: Date()) == "已开启 · 本机已检测 · 请安装 agy 或 Antigravity")
    }

    @Test @MainActor
    func failureCodesReachCardAndSettingsWithoutTheCLIMessage() throws {
        let cases: [(String, ProviderRateLimit.LiveFailure, String, String)] = [
            ("credentialsMissing", .credentialsNotFound, "运行 grok login 后可实时读取", "需登录"),
            ("credentialsRejected", .credentialsRejected, "登录已失效", "已失效"),
            ("credentialsUnreadable", .credentialsUnreadable, "读不到登录信息", "读不了"),
            ("credentialsEncrypted", .credentialsEncrypted, "登录信息已加密，暂时读不了", "不支持"),
            ("loginRefreshFailed", .loginRefreshFailed, "登录续期失败", "续期失败"),
            ("programNotFound", .programNotFound, "未找到 Grok 命令行", "未安装"),
            ("programOutdated", .programOutdated, "版本较旧，升级后可实时读取", "需升级"),
            ("programNoAnswer", .programNoAnswer, "没有返回额度", "无响应"),
            ("timedOut", .endpointTimedOut, "读取超时", "超时"),
            ("unreachable", .endpointUnreachable, "连接失败", "连不上"),
            ("httpStatus", .endpointHTTPStatus(502), "接口报错 502", "接口报错"),
            ("unrecognizedResponse", .endpointUnrecognized, "返回数据无法识别", "数据异常"),
            ("localRecordUnreadable", .localRecordUnreadable, "读不了本机记录", "读不了"),
            ("internalError", .cliFailed, "配额 CLI 出错", "CLI 出错"),
        ]
        for (code, failure, card, short) in cases {
            let result = try snapshot(.grok, status: "retryable_error", fields: ["failureReason": code, "httpStatus": 502])
            #expect(result.liveFailure == failure)
            #expect(RateLimitCardView.retryableErrorText(for: result).title == card)
            #expect(settings(result) == short)
        }
        let noNumber = try snapshot(.kimiCode, status: "retryable_error", fields: ["failureReason": "httpStatus"])
        #expect(RateLimitCardView.retryableErrorText(for: noNumber).title == "接口报错")
        let encrypted = try snapshot(.cursor, status: "unsupported", fields: ["failureReason": "credentialsEncrypted"])
        #expect(encrypted.status == .noData)
        #expect(RateLimitCardView.emptyStateText(for: encrypted, isDetected: true) == "登录信息已加密，暂时读不了")
        let unknown = try snapshot(.cursor, status: "retryable_error", fields: ["failureReason": "future"])
        #expect(unknown.liveFailure == nil)
        #expect(RateLimitCardView.retryableErrorText(for: unknown).title == "暂时读不到额度")
    }

    @Test @MainActor
    func emptyCodesExplainTheProviderRecord() throws {
        let cases: [(ProviderRateLimit.Provider, String, ProviderRateLimit.EmptyReason, String, String)] = [
            (.kimiCode, "limitReached", .limitReached, "额度已用满 · 等待重置", "已用满"),
            (.kimiCode, "noWindow", .noWindow, "没有生效的额度窗口", "无窗口"),
            (.zCode, "notEntitled", .notEntitled, "未订阅 ZCode", "未订阅"),
            (.cursor, "sessionWithoutPlanLimits", .sessionWithoutPlanLimits, "当前登录方式不含订阅额度", "不适用"),
            (.grok, "periodEnded", .periodEnded, "账期已结束 · 用一次 Grok 后更新", "待更新"),
            (.antigravity, "periodEnded", .periodEnded, "额度已重置 · 下次读取时更新", "待更新"),
            (.cursor, "periodEnded", .periodEnded, "上个周期已结束", "待更新"),
            (.grok, "noLocalRecord", .noLocalRecord, "暂无记录 · 用一次 Grok 后更新", "无记录"),
            (.antigravity, "noLocalRecord", .noLocalRecord, "用过 Antigravity 后显示", "无记录"),
            (.cursor, "noLocalRecord", .noLocalRecord, "本机暂无记录", "无记录"),
        ]
        for (provider, code, reason, card, short) in cases {
            let result = try snapshot(provider, status: "no_data", fields: ["emptyReason": code, "failureReason": "timedOut"])
            #expect(result.emptyReason == reason)
            #expect(result.liveFailure == .endpointTimedOut)
            #expect(RateLimitCardView.emptyStateText(for: result, isDetected: true) == card)
            #expect(settings(result) == short)
        }
        let unknown = try snapshot(.grok, status: "no_data", fields: ["emptyReason": "future"])
        #expect(unknown.emptyReason == nil)
        #expect(RateLimitCardView.emptyStateText(for: unknown, isDetected: true) == "没读到额度，原因未知")
    }

    @Test @MainActor
    func cacheAndLocalMetersCarryTheLiveFailureOrPause() throws {
        for (source, label) in [("cache", "缓存"), ("local", "本地日志")] {
            let result = try snapshot(.grok, status: "ok", source: source, fields: ["failureReason": "httpStatus", "httpStatus": 503])
            #expect(result.status == .ok)
            #expect(RateLimitCardView.staleDataNote(for: result) == "来源：\(label) · 接口报错 503")
            let unknown = try snapshot(.grok, status: "ok", source: source, fields: ["failureReason": "future"])
            #expect(unknown.liveFailure == (source == "cache" ? .cliReportedFailure : nil))
        }
        for (code, card) in [("proxyUnsupported", "代理无法照着走，已暂停读取"), ("proxyNotDetected", "未检测到代理，已暂停读取"),
                             ("egressUnconfirmed", "无法确认网络出口，已暂停读取"), ("egressRegionUnsupported", "网络出口在香港，已暂停读取")] {
            let fields = ["pauseReason": code, "egressRegion": "HK"]
            let paused = try snapshot(.grok, status: "unsupported", fields: fields)
            #expect(paused.status == .noData)
            #expect(paused.liveFailure?.isPause == true)
            #expect(RateLimitCardView.emptyStateText(for: paused, isDetected: true) == card)
            let local = try snapshot(.grok, status: "ok", source: "local", fields: fields)
            #expect(local.status == .ok)
            #expect(local.meters.first?.window.utilization == 30)
            #expect(RateLimitCardView.staleDataNote(for: local) == "来源：本地日志 · \(card)")
            #expect(settings(local) == "已暂停")
        }
    }

    @Test
    func cursorAndAntigravityPreserveAllQuotaWindowsAndResets() throws {
        for id in ["cursor", "antigravity"] {
            let envelope = try QuotaCLIBridge.decode(payload.replacingOccurrences(of: "kimi-code", with: id))
            let snapshot = try #require(QuotaCLIBridge.snapshots(from: envelope).first)
            #expect(snapshot.provider.rawValue == id)
            #expect(snapshot.status == .ok)
            #expect(snapshot.meters.first?.window.utilization == 42.5)
            #expect(snapshot.meters.first?.window.resetsAt != nil)
            #expect(snapshot.provider.usesQuotaCLI)
        }
    }

    @Test
    func cursorMonthCarriesItsSplitAndOnDemandReadsLikeClaudeExtra() throws {
        let envelope = try QuotaCLIBridge.decode("""
        {"schemaVersion":1,"products":[{"id":"cursor","status":"ok","fetchedAt":"2026-10-23T00:00:00Z","source":"live",
          "meters":[
            {"id":"plan","label":"Month","utilization":48,"resetsAt":"2026-11-01T00:00:00Z","windowSeconds":2678400,
             "breakdown":[{"id":"auto","label":"Cursor models","utilization":4},{"id":"api","label":"Third-party models","utilization":88}]},
            {"id":"on-demand","label":"On-demand","utilization":25}]}]}
        """)
        let snapshot = try #require(QuotaCLIBridge.snapshots(from: envelope).first)
        #expect(snapshot.meters.map(\.label) == ["Month", "额外"])
        #expect(snapshot.meters[0].window.windowDuration == 2_678_400)
        #expect(snapshot.meters[0].breakdown == [
            RateLimitMeter.Part(label: "Cursor 模型", utilization: 4),
            RateLimitMeter.Part(label: "第三方模型", utilization: 88),
        ])
        #expect(snapshot.meters[1].breakdown.isEmpty)
    }

    private let payload = """
    {
      "schemaVersion": 1,
      "products": [{
        "id": "kimi-code",
        "status": "ok",
        "meters": [{
          "id": "weekly",
          "label": "7d",
          "utilization": 42.5,
          "resetsAt": "2026-09-14T00:00:00.000Z",
          "windowSeconds": 604800
        }],
        "planLabel": "Pro",
        "fetchedAt": "2026-09-07T00:00:00.000Z",
        "dataAsOf": "2026-09-07T00:00:00.000Z",
        "source": "live"
      }]
    }
    """

    @Test
    func decodesVersionedMetersIntoProviderNeutralSnapshots() throws {
        let envelope = try QuotaCLIBridge.decode(payload)
        let snapshots = try QuotaCLIBridge.snapshots(from: envelope)
        let snapshot = try #require(snapshots.first)
        let meter = try #require(snapshot.meters.first)

        #expect(snapshot.provider == .kimiCode)
        #expect(snapshot.status == .ok)
        #expect(snapshot.planLabel == "Pro")
        #expect(meter.id == "weekly")
        #expect(meter.label == "7d")
        #expect(meter.window.utilization == 42.5)
        #expect(meter.window.windowDuration == 604_800)
        #expect(meter.window.resetsAt == Date(timeIntervalSince1970: 1_789_344_000))
    }

    @Test
    func rejectsAnUnknownSchemaBeforeUsingAnyProductData() throws {
        let envelope = QuotaCLIBridge.Envelope(schemaVersion: 2, products: [])
        #expect(throws: QuotaCLIBridge.ProtocolError.self) {
            _ = try QuotaCLIBridge.snapshots(from: envelope)
        }
    }

    @Test
    func mapsCredentialAndTransientFailuresPerProvider() throws {
        let credential = QuotaCLIBridge.Product(
            id: "zcode",
            status: "missing_credentials",
            meters: [],
            fetchedAt: Date(),
            source: "live"
        )
        let transient = QuotaCLIBridge.Product(
            id: "kimi-code",
            status: "retryable_error",
            meters: [],
            fetchedAt: Date(),
            source: "live"
        )
        let snapshots = try QuotaCLIBridge.snapshots(from: .init(
            schemaVersion: 1,
            products: [credential, transient]
        ))

        #expect(snapshots.first(where: { $0.provider == .zCode })?.status == .unauthorized)
        #expect(snapshots.first(where: { $0.provider == .kimiCode })?.status == .retryableError)
    }

    @Test
    func decodesGrokAsAReadOnlyLocalCLIProvider() throws {
        let product = QuotaCLIBridge.Product(
            id: "grok",
            status: "ok",
            meters: [.init(
                id: "subscription-credits",
                label: "7d",
                utilization: 30,
                resetsAt: Date(timeIntervalSince1970: 1_789_344_000),
                windowSeconds: 604_800
            )],
            planLabel: "X Premium+",
            fetchedAt: Date(timeIntervalSince1970: 1_788_739_200),
            dataAsOf: Date(timeIntervalSince1970: 1_788_739_200),
            source: "local"
        )

        let snapshots = try QuotaCLIBridge.snapshots(from: .init(
            schemaVersion: 1,
            products: [product]
        ))
        let snapshot = try #require(snapshots.first)

        #expect(snapshot.provider == .grok)
        #expect(snapshot.status == .ok)
        #expect(snapshot.planLabel == "X Premium+")
        #expect(snapshot.meters.first?.window.utilization == 30)
    }

    /// The CLI's `source` is carried through, and a cached answer (which the
    /// CLI returns only after a live `retryable_error`) is marked as a failed
    /// live read. The free-text `message` is never used.
    @Test
    func carriesTheCLISourceAndMarksCachedAnswers() throws {
        func product(_ id: String, source: String) -> QuotaCLIBridge.Product {
            QuotaCLIBridge.Product(
                id: id,
                status: "ok",
                meters: [.init(id: "weekly", label: "7d", utilization: 10)],
                fetchedAt: Date(timeIntervalSince1970: 100),
                source: source,
                message: "Kimi usage request failed for vbu_secret at /Users/张三"
            )
        }
        let snapshots = try QuotaCLIBridge.snapshots(from: .init(schemaVersion: 1, products: [
            product("kimi-code", source: "cache"),
            product("grok", source: "local"),
            product("zcode", source: "live"),
            product("cursor", source: "something-new"),
        ]))
        func snapshot(_ provider: ProviderRateLimit.Provider) -> ProviderRateLimit? {
            snapshots.first { $0.provider == provider }
        }

        #expect(snapshot(.kimiCode)?.source == .cache)
        #expect(snapshot(.kimiCode)?.liveFailure == .cliReportedFailure)
        #expect(snapshot(.grok)?.source == .localLog)
        #expect(snapshot(.grok)?.liveFailure == nil)
        #expect(snapshot(.zCode)?.source == .live)
        #expect(snapshot(.zCode)?.liveFailure == nil)
        #expect(snapshot(.cursor)?.source == nil)
    }

    @Test
    func envelopeFailuresMapToFixedReasonsWithoutProcessOutput() throws {
        #expect(QuotaCLIBridge.liveFailure(for: CLIBridge.CLIError.noRuntime) == .cliRuntimeMissing)
        #expect(QuotaCLIBridge.liveFailure(for: CLIBridge.CLIError.timeout) == .cliTimedOut)
        #expect(QuotaCLIBridge.liveFailure(
            for: CLIBridge.CLIError.processFailure("npm ERR! /Users/张三/.npm vbu_secret")
        ) == .cliFailed)
        #expect(QuotaCLIBridge.liveFailure(
            for: QuotaCLIBridge.ProtocolError.unsupportedSchema(2)
        ) == .cliSchemaMismatch)
        #expect(QuotaCLIBridge.liveFailure(
            for: QuotaCLIBridge.ProtocolError.unknownProduct("future")
        ) == .cliUnrecognizedOutput)
        var decodingError: Error?
        do { _ = try QuotaCLIBridge.decode("not json") } catch { decodingError = error }
        #expect(QuotaCLIBridge.liveFailure(for: try #require(decodingError)) == .cliUnrecognizedOutput)
    }

    @Test
    func exposesZCodeKeyOnlyWhenZCodeIsExplicitlyRequested() {
        let kimiOnly = QuotaCLIBridge.quotaEnvironment(
            providers: [.kimiCode],
            zCodeAPIKey: "secret-fixture"
        )
        #expect(kimiOnly.overrides.isEmpty)
        #expect(kimiOnly.keysToRemove == ["BIGMODEL_API_KEY", "Z_AI_API_KEY"])

        let zAI = QuotaCLIBridge.quotaEnvironment(
            providers: [.zCode],
            zCodeAPIKey: "  secret-fixture  ",
            zCodeRegion: .zAI
        )
        #expect(zAI.overrides == ["Z_AI_API_KEY": "secret-fixture"])
        #expect(zAI.keysToRemove == ["BIGMODEL_API_KEY"])

        let bigModel = QuotaCLIBridge.quotaEnvironment(
            providers: [.zCode],
            zCodeAPIKey: "bigmodel-secret",
            zCodeRegion: .bigModel
        )
        #expect(bigModel.overrides == ["BIGMODEL_API_KEY": "bigmodel-secret"])
        #expect(bigModel.keysToRemove == ["Z_AI_API_KEY"])
    }
}
