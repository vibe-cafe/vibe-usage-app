import Foundation

/// Typed boundary for the CLI's versioned, JSON-only quota protocol.
enum QuotaCLIBridge {
    static let schemaVersion = 1

    struct Envelope: Decodable, Equatable {
        var schemaVersion: Int
        var products: [Product]
    }

    struct Product: Decodable, Equatable {
        var id: String
        var status: String
        var meters: [Meter]
        var planLabel: String?
        var fetchedAt: Date
        var dataAsOf: Date?
        var source: String
        var message: String?
    }

    struct Meter: Decodable, Equatable {
        var id: String
        var label: String
        var utilization: Double
        var resetsAt: Date?
        var windowSeconds: Double?
    }

    enum ProtocolError: LocalizedError {
        case unsupportedSchema(Int)
        case unknownProduct(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let value):
                return "本地配额协议版本不兼容（收到 \(value)，需要 \(schemaVersion)）"
            case .unknownProduct(let id):
                return "本地配额协议返回了未知产品：\(id)"
            }
        }
    }

    static func fetch(
        providers: [ProviderRateLimit.Provider],
        zCodeAPIKey: String?,
        zCodeRegion: ZCodeQuotaRegion = .zAI
    ) async throws -> [ProviderRateLimit] {
        let supported = providers.filter(\.usesQuotaCLI)
        guard !supported.isEmpty else { return [] }
        let environment = quotaEnvironment(
            providers: supported,
            zCodeAPIKey: zCodeAPIKey,
            zCodeRegion: zCodeRegion
        )
        var arguments = ["quota", "fetch"]
        for provider in supported {
            arguments += ["--product", provider.rawValue]
        }
        arguments.append("--json")
        let output = try await CLIBridge.runCLI(
            args: arguments,
            timeout: 30,
            environmentOverrides: environment.overrides,
            environmentKeysToRemove: environment.keysToRemove
        )
        return try snapshots(from: decode(output))
    }

    /// A saved regional key is exposed only to a subprocess that was explicitly
    /// asked to fetch ZCode. The other region and Kimi-only calls actively scrub
    /// both credential variables so a key can never be sent to the wrong host.
    static func quotaEnvironment(
        providers: [ProviderRateLimit.Provider],
        zCodeAPIKey: String?,
        zCodeRegion: ZCodeQuotaRegion = .zAI
    ) -> (overrides: [String: String], keysToRemove: Set<String>) {
        let allKeys = Set(ZCodeQuotaRegion.allCases.map(\.environmentKey))
        let key = providers.contains(.zCode)
            ? zCodeAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        guard let key, !key.isEmpty else { return ([:], allKeys) }
        return (
            [zCodeRegion.environmentKey: key],
            allKeys.subtracting([zCodeRegion.environmentKey])
        )
    }

    static func decode(_ output: String) throws -> Envelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return try decoder.decode(Envelope.self, from: Data(output.utf8))
    }

    static func snapshots(from envelope: Envelope) throws -> [ProviderRateLimit] {
        guard envelope.schemaVersion == schemaVersion else {
            throw ProtocolError.unsupportedSchema(envelope.schemaVersion)
        }
        return try envelope.products.map { product in
            guard let provider = ProviderRateLimit.Provider(rawValue: product.id),
                  provider.usesQuotaCLI
            else { throw ProtocolError.unknownProduct(product.id) }

            let status: ProviderRateLimit.Status
            switch product.status {
            case "ok": status = product.meters.isEmpty ? .noData : .ok
            case "no_data", "unsupported": status = .noData
            case "missing_credentials", "expired_credentials", "unauthorized": status = .unauthorized
            case "retryable_error": status = .retryableError
            default: status = .error("无法识别本地配额状态")
            }
            return ProviderRateLimit(
                provider: provider,
                meters: product.meters.map { meter in
                    RateLimitMeter(
                        id: meter.id,
                        label: meter.label,
                        window: RateLimitWindow(
                            utilization: meter.utilization,
                            resetsAt: meter.resetsAt,
                            windowDuration: meter.windowSeconds
                        )
                    )
                },
                planLabel: product.planLabel,
                status: status,
                fetchedAt: product.fetchedAt,
                dataAsOf: product.dataAsOf
            )
        }
    }
}

extension ProviderRateLimit.Provider {
    /// Providers implemented by the shared, schema-versioned CLI boundary.
    /// Cursor deliberately stays outside until it has an official stable
    /// quota protocol; selecting it must never start a subprocess or request.
    var usesQuotaCLI: Bool {
        switch self {
        case .kimiCode, .zCode, .grok: return true
        case .codex, .claudeCode, .cursor, .opencodeGo: return false
        }
    }
}
