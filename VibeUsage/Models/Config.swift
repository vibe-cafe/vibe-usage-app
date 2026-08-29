import Foundation

/// Mirrors ~/.vibe-usage/config.json structure
struct VibeUsageConfig: Codable {
    var apiKey: String?
    var apiUrl: String?
    var lastSync: String?
    var codexExtraHome: String?
}

enum ConfigManager {
    private static let configDir = ProcessInfo.processInfo.environment["VIBE_USAGE_CONFIG_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibe-usage")
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

    /// Merge app-owned values into the shared CLI config without dropping
    /// fields introduced by newer CLI versions (privacy controls, device id,
    /// cached server settings, and future additions).
    static func save(_ config: VibeUsageConfig) {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let existingData = try? Data(contentsOf: configFile)
            let data = try mergedConfigData(config, existingData: existingData)
            try data.write(to: configFile, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configFile.path
            )
        } catch {
            print("Failed to save config: \(error)")
        }
    }

    static func mergedConfigData(
        _ config: VibeUsageConfig,
        existingData: Data?
    ) throws -> Data {
        var merged: [String: Any] = [:]
        if let existingData,
           let object = try? JSONSerialization.jsonObject(with: existingData),
           let existing = object as? [String: Any] {
            merged = existing
        }

        let encoded = try JSONEncoder().encode(config)
        let appValues = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        for (key, value) in appValues {
            merged[key] = value
        }

        return try JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Check if config exists and has an API key
    static var isConfigured: Bool {
        load()?.apiKey != nil
    }
}
