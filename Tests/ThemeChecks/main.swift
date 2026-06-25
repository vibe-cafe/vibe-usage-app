import Foundation
import VibeUsageCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("ThemeChecks failed: \(message)\n".utf8))
        Foundation.exit(1)
    }
}

expect(AppTheme.allCases.map(\.rawValue) == ["dark", "light", "grass", "gold"],
       "themes must expose stable raw values")
expect(AppTheme.allCases.map(\.displayName) == ["暗黑", "浅色", "青草", "金色"],
       "themes must expose Chinese display names")
expect(AppTheme.storedValue("missing") == .dark,
       "invalid stored values must fall back to dark")
expect(AppTheme.storedValue(nil) == .dark,
       "missing stored values must fall back to dark")

let suiteName = "ai.vibecafe.vibe-usage.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer {
    defaults.removePersistentDomain(forName: suiteName)
}

AppTheme.gold.save(to: defaults)
expect(defaults.string(forKey: AppTheme.userDefaultsKey) == "gold",
       "theme persistence must use stable raw values")
expect(AppTheme.load(from: defaults) == .gold,
       "theme loading must return the stored theme")
