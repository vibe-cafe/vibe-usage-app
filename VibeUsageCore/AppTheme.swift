import Foundation

public enum AppTheme: String, CaseIterable, Identifiable {
    case dark
    case light
    case grass
    case gold

    public static let userDefaultsKey = "appTheme"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dark: return "暗黑"
        case .light: return "浅色"
        case .grass: return "青草"
        case .gold: return "金色"
        }
    }

    public static func storedValue(_ rawValue: String?) -> AppTheme {
        guard let rawValue, let theme = AppTheme(rawValue: rawValue) else {
            return .dark
        }
        return theme
    }

    public static func load(from defaults: UserDefaults = .standard) -> AppTheme {
        storedValue(defaults.string(forKey: userDefaultsKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }
}
