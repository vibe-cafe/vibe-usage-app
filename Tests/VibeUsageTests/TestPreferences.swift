import Foundation

/// Issue #126: a `UserDefaults(suiteName:)` domain named like
/// `Foo.<UUID>` leaves an empty plist in `~/Library/Preferences` even after
/// `removePersistentDomain(forName:)` (preferences write it asynchronously,
/// after the test). An absolute path as the suite name stores the domain at
/// that path instead, so these domains live in a temporary folder of their
/// own, removed when the test finishes; nothing lands in
/// `~/Library/Preferences`.
enum TestPreferences {
    static func makeDomain(_ prefix: String) -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("preferences").path
    }

    static func remove(_ domain: String) {
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        let folder = URL(fileURLWithPath: domain).deletingLastPathComponent()
        guard folder.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
