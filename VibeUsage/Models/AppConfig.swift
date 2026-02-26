import Foundation

enum AppConfig {
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