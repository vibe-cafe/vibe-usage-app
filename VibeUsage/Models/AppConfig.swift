import Foundation

enum AppConfig {
    static let version = "0.8.1"
    static let interfaceStyleReleased = false

    #if VIBE_USAGE_EXTERNAL_TEST
    static let displayName = "Vibe Usage Test"
    static let isExternalTest = true
    #else
    static let displayName = "Vibe Usage"
    static let isExternalTest = false
    #endif

    static let cliIdentityEnvironment = [
        "VIBE_USAGE_SURFACE": "mac-app",
        "VIBE_USAGE_SURFACE_VERSION": version,
    ]

    static let productionApiUrl = "https://vibefriends.com"

    #if DEBUG
    static let defaultApiUrl = "http://localhost:3000"
    static let configFileName = "config.dev.json"
    static let isDev = true
    #else
    static let defaultApiUrl = productionApiUrl
    static let configFileName = "config.json"
    static let isDev = false
    #endif
}

/// The configured Vibe Usage server for API requests, device linking and web pages.
struct UsageServer: Sendable, Equatable {
    private static let legacyOrigins = ["https://vibecafe.ai", "https://www.vibecafe.ai"]
    let baseURL: String

    init(_ address: String?) {
        guard let address, !address.isEmpty else {
            baseURL = AppConfig.defaultApiUrl
            return
        }
        baseURL = Self.legacyOrigins.contains(Self.comparisonForm(address)) ? AppConfig.productionApiUrl : address
    }

    private static func comparisonForm(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacing(/\/+$/, with: "")
    }

    var siteURL: URL? { URL(string: baseURL) }

    func url(for path: String) -> URL? {
        siteURL?.appendingPathComponent(path)
    }

    /// Device authorization supplies a complete URL, including the user code.
    /// A custom server owns its approval URL, which can use a separate identity host.
    func verificationURL(_ address: String) -> URL? {
        guard Self.comparisonForm(baseURL) == AppConfig.productionApiUrl else { return URL(string: address) }
        for origin in Self.legacyOrigins where address.lowercased().hasPrefix(origin) {
            let suffix = address.dropFirst(origin.count)
            if let first = suffix.first, !"/?#".contains(first) { continue }
            return URL(string: AppConfig.productionApiUrl + suffix)
        }
        return URL(string: address)
    }
}
