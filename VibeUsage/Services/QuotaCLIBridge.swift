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
        var emptyReason: String?
        var failureReason: String?
        var httpStatus: Int?
        /// A paused live read can still report meters from a local record.
        var pauseReason: String?
        var egressRegion: String?
        /// Cursor only (vibe-cafe/vibe-usage#210): `required` when Cursor's
        /// own login cannot be read (encrypted, issue #144), `expired` when
        /// the separate Vibe Usage sign-in was ended or lapsed.
        var signIn: String?
    }

    struct Meter: Decodable, Equatable {
        var id: String
        var label: String
        var utilization: Double
        var resetsAt: Date?
        var windowSeconds: Double?
        var breakdown: [Part]?

        struct Part: Decodable, Equatable {
            var id: String
            var label: String
            var utilization: Double
        }
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
        guard supported.contains(.cursor) else {
            return try await run(supported, zCodeAPIKey: zCodeAPIKey, zCodeRegion: zCodeRegion)
        }
        // The Cursor sign-in Vibe Usage keeps (`CursorLogin`) goes on stdin,
        // renewed first when it is due; never in the environment or argv.
        let login = await CursorLogin.shared
        let passed = await login.credentialForCLI()
        var results = try await run(
            supported, zCodeAPIKey: zCodeAPIKey, zCodeRegion: zCodeRegion, cursorLogin: passed
        )
        guard let index = results.firstIndex(where: { $0.provider == .cursor }) else { return results }
        if results[index].liveFailure?.isCursorSignIn == true { await login.noteCLISupportsSignIn() }
        // Cursor rejected the sign-in we passed (or it lapsed): renew once and
        // read again, as the CLI does for a sign-in it stores itself.
        guard let passed, passed.hasCredential, results[index].liveFailure == .signInExpired else { return results }
        switch await login.renewAfterRejection(of: passed) {
        case .renewed(let next):
            do {
                if let retry = try await run([.cursor], zCodeAPIKey: nil, cursorLogin: next).first {
                    results[index] = retry
                    // The renewed one is rejected too: it ends (no new request).
                    if retry.liveFailure == .signInExpired { _ = await login.renewAfterRejection(of: next) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Renewed, but reading again did not complete: not "expired".
                results[index] = ProviderRateLimit(
                    provider: .cursor, status: .retryableError, fetchedAt: Date(),
                    source: .live, liveFailure: liveFailure(for: error)
                )
            }
        case .ended:
            break
        case .notRenewed:
            // Still within its lifetime: the renewal is what failed.
            if let expiry = passed.expiresAt, expiry > Date() {
                results[index] = ProviderRateLimit(
                    provider: .cursor, status: .retryableError,
                    fetchedAt: results[index].fetchedAt ?? Date(),
                    source: .live, liveFailure: .loginRefreshFailed
                )
            }
        }
        return results
    }

    private static func run(
        _ providers: [ProviderRateLimit.Provider],
        zCodeAPIKey: String?,
        zCodeRegion: ZCodeQuotaRegion = .zAI,
        cursorLogin: CursorLoginRecord? = nil
    ) async throws -> [ProviderRateLimit] {
        let environment = quotaEnvironment(
            providers: providers,
            zCodeAPIKey: zCodeAPIKey,
            zCodeRegion: zCodeRegion
        )
        var arguments = ["quota", "fetch"]
        for provider in providers {
            arguments += ["--product", provider.rawValue]
        }
        arguments.append("--json")
        if cursorLogin != nil { arguments.append("--cursor-login-stdin") }
        let output = try await CLIBridge.runCLI(
            args: arguments,
            timeout: 30,
            environmentOverrides: environment.overrides,
            environmentKeysToRemove: environment.keysToRemove,
            standardInput: cursorLogin?.data
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
            var liveFailure = failure(reason: product.failureReason, httpStatus: product.httpStatus)
            switch product.status {
            case "ok": status = product.meters.isEmpty ? .noData : .ok
            case "no_data", "unsupported": status = .noData
            case "missing_credentials":
                status = .unauthorized
                liveFailure = liveFailure ?? (provider == .antigravity ? .programNotFound : .credentialsNotFound)
            case "expired_credentials", "unauthorized":
                status = .unauthorized
                liveFailure = liveFailure ?? .credentialsRejected
            case "retryable_error": status = .retryableError
            default: status = .error("无法识别本地配额状态")
            }
            if product.status == "ok" || product.status == "unsupported" {
                liveFailure = pauseFailure(reason: product.pauseReason, region: product.egressRegion) ?? liveFailure
            }
            if liveFailure == nil, product.source == "cache" {
                liveFailure = .cliReportedFailure
            }
            if provider == .cursor, product.status == "unsupported" {
                switch product.signIn {
                case "required": liveFailure = .signInRequired
                case "expired": liveFailure = .signInExpired
                default: break
                }
            }
            return ProviderRateLimit(
                provider: provider,
                meters: product.meters.map { meter in
                    RateLimitMeter(
                        id: meter.id,
                        label: displayLabel(meterID: meter.id, label: meter.label, provider: provider),
                        window: RateLimitWindow(
                            utilization: meter.utilization,
                            resetsAt: meter.resetsAt,
                            windowDuration: meter.windowSeconds
                        ),
                        breakdown: (meter.breakdown ?? []).map {
                            RateLimitMeter.Part(
                                label: displayLabel(meterID: $0.id, label: $0.label, provider: provider),
                                utilization: $0.utilization
                            )
                        }
                    )
                },
                planLabel: product.planLabel,
                status: status,
                fetchedAt: product.fetchedAt,
                dataAsOf: product.dataAsOf,
                emptyReason: emptyReason(product.emptyReason),
                source: source(product.source),
                liveFailure: liveFailure
            )
        }
    }

    private static func emptyReason(_ reason: String?) -> ProviderRateLimit.EmptyReason? {
        switch reason {
        case "limitReached": .limitReached
        case "noWindow": .noWindow
        case "notEntitled": .notEntitled
        case "sessionWithoutPlanLimits": .sessionWithoutPlanLimits
        case "periodEnded": .periodEnded
        case "noLocalRecord": .noLocalRecord
        default: nil
        }
    }

    private static func failure(reason: String?, httpStatus: Int?) -> ProviderRateLimit.LiveFailure? {
        switch reason {
        case "credentialsMissing": .credentialsNotFound
        case "credentialsRejected": .credentialsRejected
        case "credentialsUnreadable": .credentialsUnreadable
        case "credentialsEncrypted": .credentialsEncrypted
        case "loginRefreshFailed": .loginRefreshFailed
        case "programNotFound": .programNotFound
        case "programOutdated": .programOutdated
        case "programNoAnswer": .programNoAnswer
        case "timedOut": .endpointTimedOut
        case "unreachable": .endpointUnreachable
        case "httpStatus": .endpointHTTPStatus(httpStatus)
        case "unrecognizedResponse": .endpointUnrecognized
        case "localRecordUnreadable": .localRecordUnreadable
        case "internalError": .cliFailed
        default: nil
        }
    }

    /// Unknown pause codes stay nil.
    static func pauseFailure(reason: String?, region: String?) -> ProviderRateLimit.LiveFailure? {
        switch reason {
        case "egressRegionUnsupported":
            let code = region.flatMap { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isUppercase } ? $0 : nil }
            return .egressRegionUnsupported(code ?? "")
        case "egressUnconfirmed": return .egressUnconfirmed
        case "proxyNotDetected": return .proxyNotDetected
        case "proxyUnsupported": return .proxyUnsupported
        default: return nil
        }
    }

    /// The CLI's `source` field. Unknown values stay nil rather than guessed.
    static func source(_ raw: String) -> ProviderRateLimit.Source? {
        switch raw {
        case "live": return .live
        case "cache": return .cache
        case "local": return .localLog
        default: return nil
        }
    }

    /// Fixed reason for a whole-envelope failure. Process output (stderr, a
    /// launcher message) is deliberately dropped: it is free text that can
    /// carry paths or credentials.
    static func liveFailure(for error: Error) -> ProviderRateLimit.LiveFailure {
        switch error {
        case CLIBridge.CLIError.noRuntime: return .cliRuntimeMissing
        case CLIBridge.CLIError.timeout: return .cliTimedOut
        case CLIBridge.CLIError.processFailure: return .cliFailed
        case ProtocolError.unsupportedSchema: return .cliSchemaMismatch
        case ProtocolError.unknownProduct, is DecodingError: return .cliUnrecognizedOutput
        default: return .cliFailed
        }
    }

    /// The CLI speaks English labels; the cards are Chinese. Only ids this app
    /// knows are renamed, so a new CLI meter still renders as reported.
    static func displayLabel(meterID: String, label: String, provider: ProviderRateLimit.Provider) -> String {
        guard provider == .cursor else { return label }
        switch meterID {
        // Same row name as Claude's pay-as-you-go spend.
        case "on-demand": return "额外"
        case "auto": return "Cursor 模型"
        case "api": return "第三方模型"
        default: return label
        }
    }
}

extension ProviderRateLimit.Provider {
    /// Providers implemented by the shared, schema-versioned CLI boundary.
    var usesQuotaCLI: Bool {
        switch self {
        case .kimiCode, .zCode, .grok, .cursor, .antigravity: return true
        case .codex, .claudeCode, .opencodeGo: return false
        }
    }
}
