import Foundation
import Testing
@testable import VibeUsage

struct QuotaCLIBridgeTests {
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
