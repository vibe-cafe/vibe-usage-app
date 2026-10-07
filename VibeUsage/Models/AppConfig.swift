import Foundation

enum AppConfig {
    static let version = "0.7.1"

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

    #if DEBUG
    static let defaultApiUrl = "http://localhost:3000"
    static let configFileName = "config.dev.json"
    static let isDev = true
    #else
    static let defaultApiUrl = "https://vibecafe.ai"
    static let configFileName = "config.json"
    static let isDev = false
    #endif
}
