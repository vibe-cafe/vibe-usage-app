import Foundation

/// Mirrors ~/.vibe-usage/config.json structure
struct VibeUsageConfig: Codable {
    var apiKey: String?
    var apiUrl: String?
    var lastSync: String?
}

enum ConfigManager {
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vibe-usage")
    private static let configFile = configDir.appendingPathComponent(AppConfig.configFileName)

    static func load() -> VibeUsageConfig? {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: configFile)
            return try JSONDecoder().decode(VibeUsageConfig.self, from: data)
        } catch {
            print("Failed to load config: \(error)")
            return nil
        }
    }

    /// Save config to disk
    static func save(_ config: VibeUsageConfig) {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configFile)
        } catch {
            print("Failed to save config: \(error)")
        }
    }

    /// Check if config exists and has an API key
    static var isConfigured: Bool {
        load()?.apiKey != nil
    }
}
