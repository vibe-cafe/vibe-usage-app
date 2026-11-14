import Foundation
import Testing
@testable import VibeUsage

/// `cli-bootstrap.mjs` as the app sees it. Synthetic data only: temporary
/// directories, fake cached CLI versions, a stubbed `fetch`.
struct CLILauncherTests {
    static let launcher = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("VibeUsage/Resources/cli-bootstrap.mjs")

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A cache entry the way the launcher leaves it after an install.
    private func cache(_ root: URL, _ name: String, complete: Bool = true, entry: Bool = true,
                       body: String? = nil) throws {
        let package = root.appendingPathComponent("cli-cache/\(name)/package")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        try #"{"name":"fake","type":"module"}"#.write(to: package.appendingPathComponent("package.json"),
                                                       atomically: true, encoding: .utf8)
        if entry {
            let source = body ?? "export async function run(argv) { process.stdout.write('ran \(name) ' + argv.join(' ') + '\\n'); }\n"
            try source.write(to: package.appendingPathComponent("src/index.js"), atomically: true, encoding: .utf8)
        }
        if complete {
            try name.write(to: root.appendingPathComponent("cli-cache/\(name)/complete"),
                           atomically: true, encoding: .utf8)
        }
    }

    @Test
    func theBundledCopyIsTheWindowsLauncher() throws {
        let text = try String(contentsOf: Self.launcher, encoding: .utf8)
        #expect(text.contains("const NOTICE_PREFIX = 'vibe-usage launcher notice:';"))
        #expect(text.contains("process.stderr.write(`vibe-usage launcher: ${message}\\n`);"))
        #expect(text.contains("const PACKAGE = '@vibe-cafe/vibe-usage';"))
    }

    // MARK: - Cache

    @Test
    func newestCachedVersionFollowsTheLaunchersRules() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cli-cache")
        #expect(CLILauncher.newestCachedVersion(in: directory) == nil)

        for name in ["0.9.0", "0.14.9", "0.14.11", "0.14.11-rc.1", "not-a-version",
                     ".staging-4242-1794205920000-abc"] {
            try cache(root, name)
        }
        try cache(root, "0.15.0", complete: false)
        try cache(root, "0.15.1", entry: false)
        // Numeric order (0.14.11 > 0.14.9 > 0.9.0), a release before its
        // prerelease, and only complete entries with the entry file.
        #expect(CLILauncher.newestCachedVersion(in: directory) == "0.14.11")
    }

    @Test
    func cacheLivesWhereTheLauncherPutsIt() {
        #expect(CLILauncher.cacheDirectory(environment: [:]).path
            == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibe-usage/cli-cache").path)
        #expect(CLILauncher.cacheDirectory(environment: ["VIBE_USAGE_CONFIG_DIR": "/tmp/vu"]).path == "/tmp/vu/cli-cache")
    }

    // MARK: - Output

    @Test
    func noticeIsRemovedAndItsStageKept() {
        let notice = "vibe-usage launcher notice: stage=download; running cached @vibe-cafe/vibe-usage@0.14.11 because latest is unavailable (x)"
        #expect(CLILauncher.withoutNotice("  \(notice)\r\nCursor usage export skipped\r\n") == "Cursor usage export skipped")
        #expect(CLILauncher.withoutNotice(notice) == "")
        #expect(CLILauncher.withoutNotice("  ✗ x\n") == "  ✗ x\n")
        #expect(CLILauncher.fallbackStage(in: "Cursor usage export skipped\r\n  \(notice)\r\n") == .download)
        #expect(CLILauncher.fallbackStage(in: "vibe-usage launcher notice: running cached") == .other)
        #expect(CLILauncher.fallbackStage(in: "vibe-usage launcher: TypeError: fetch failed") == nil)
        #expect(CLILauncher.fallbackStage(in: "✗ 同步失败: fetch failed") == nil)
    }

    // MARK: - The real launcher, offline

    /// The shipped launcher run by a system Node with `fetch` stubbed, the
    /// way the Windows tests do it: what it prints is what the app classifies.
    /// Skipped where no Node is installed.
    @Test
    func realLauncherOutputIsClassifiedAsExpected() async throws {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let node = (path + ["/opt/homebrew/bin", "/usr/local/bin"])
            .map({ "\($0)/node" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let stub = home.appendingPathComponent("stub.mjs")
        try """
        globalThis.fetch = async () => {
          throw new TypeError("fetch failed", { cause: Object.assign(new Error("connect ETIMEDOUT 104.16.0.35:443"), { code: "ETIMEDOUT" }) });
        };
        """.write(to: stub, atomically: true, encoding: .utf8)

        func launch() async throws -> CLIProcessRunner.Output {
            try await CLIProcessRunner.run(
                executable: node,
                arguments: ["--import=\(stub.absoluteString)", Self.launcher.path, "sync"],
                environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "VIBE_USAGE_CONFIG_DIR": home.path],
                timeout: 30
            )
        }

        // Nothing cached: the CLI never runs.
        let empty = try await launch()
        #expect(empty.exitCode == 1)
        #expect(SyncEngine.outcome(for: empty)
            == .init(result: .launchFailed, reason: .launcherFailed, launcherStage: .network))

        // A cached version stands in and its own result counts.
        try cache(home, "0.14.11")
        let cached = try await launch()
        #expect(cached.exitCode == 0)
        #expect(cached.stdout == "ran 0.14.11 sync\n")
        #expect(SyncEngine.outcome(for: cached) == .init(result: .success, cliFallback: .network))

        // The cached CLI's own failure stays the CLI's failure.
        try cache(home, "0.14.12", body: "export async function run() { process.stderr.write('✗ 同步失败: HTTP 502: bad gateway\\n'); process.exit(1); }\n")
        let failing = try await launch()
        #expect(SyncEngine.outcome(for: failing)
            == .init(result: .failure, reason: .serverError, httpStatus: 502, cliFallback: .network))
    }
}
