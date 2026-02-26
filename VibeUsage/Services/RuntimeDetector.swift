import Foundation

/// Detects available Node.js runtime (bun preferred, npx fallback)
enum RuntimeDetector {
    struct Runtime {
        let executablePath: String
        let name: String /// "bun" or "npx"

        /// Arguments to run vibe-usage sync
        var syncArguments: [String] {
            switch name {
            case "bun":
                return ["x", "@vibe-cafe/vibe-usage", "sync"]
            default:
                return ["--yes", "@vibe-cafe/vibe-usage", "sync"]
            }
        }
    }

    /// Search common paths where node/bun might be installed
    private static let searchPaths: [String] = {
        // Start with PATH from environment
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        // Add common install locations that might not be in PATH
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(contentsOf: [
            "\(home)/.bun/bin",
            "\(home)/.nvm/versions/node/current/bin",
            "\(home)/.volta/bin",
            "\(home)/.fnm/current/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/local/bin",
        ])

        return paths
    }()

    /// Detect the best available JS runtime
    static func detect() -> Runtime? {
        // Prefer bun for speed
        if let bunPath = findExecutable("bun") {
            return Runtime(executablePath: bunPath, name: "bun")
        }
        if let npxPath = findExecutable("npx") {
            return Runtime(executablePath: npxPath, name: "npx")
        }
        return nil
    }

    private static func findExecutable(_ name: String) -> String? {
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
