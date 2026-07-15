import Foundation

enum AppConfig {
    static let version = "0.5.3"

    #if DEBUG
    /// DEBUG-only override so a dev build can be pointed at a real backend
    /// (e.g. `VIBE_USAGE_API_URL=https://vibecafe.ai`) for end-to-end login
    /// testing without hardcoding — falls back to the local dev server when
    /// unset. Has no effect on release builds.
    static let defaultApiUrl = ProcessInfo.processInfo.environment["VIBE_USAGE_API_URL"] ?? "http://localhost:3000"
    static let configFileName = "config.dev.json"
    static let isDev = true
    #else
    static let defaultApiUrl = "https://vibecafe.ai"
    static let configFileName = "config.json"
    static let isDev = false
    #endif
}
