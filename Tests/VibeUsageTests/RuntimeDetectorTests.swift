import XCTest
@testable import VibeUsage

final class RuntimeDetectorTests: XCTestCase {
    private let launcher = "/Applications/Vibe Usage.app/Contents/Resources/VibeUsage_VibeUsage.bundle/cli-bootstrap.mjs"
    private let bundled = "/Applications/Vibe Usage.app/Contents/Helpers/node"

    // MARK: - Arguments

    func testExternalBundleUsesNpxPackageSyntaxForLocalTarball() {
        XCTAssertEqual(
            RuntimeDetector.npxArguments(
                command: ["quota", "discover", "--json"],
                packageSpecifier: "/Applications/Vibe Usage Test.app/Contents/Resources/vibe-usage-cli.tgz",
                usesBundledPackage: true
            ),
            [
                "--yes",
                "--package",
                "/Applications/Vibe Usage Test.app/Contents/Resources/vibe-usage-cli.tgz",
                "vibe-usage",
                "quota",
                "discover",
                "--json",
            ]
        )
    }

    func testNpxHookRunsTheGivenPackage() {
        XCTAssertEqual(
            RuntimeDetector.npxArguments(command: ["config", "get", "apiKey"],
                                         packageSpecifier: "/tmp/vibe-usage", usesBundledPackage: false),
            ["--yes", "/tmp/vibe-usage", "config", "get", "apiKey"]
        )
    }

    /// Bundled Node, system Node and Bun all run the launcher with the command.
    func testEveryRuntimeRunsTheLauncher() {
        for kind in [RuntimeDetector.Kind.bundledNode, .systemNode, .bun] {
            let runtime = RuntimeDetector.Runtime(kind: kind, executablePath: "/x/node", launcherPath: launcher)
            XCTAssertEqual(runtime.arguments(["sync"]), [launcher, "sync"])
            XCTAssertEqual(runtime.arguments(["quota", "fetch", "--json"]), [launcher, "quota", "fetch", "--json"])
        }
    }

    func testReleaseCLIStaysOnLatest() {
        XCTAssertEqual(RuntimeDetector.defaultPackageSpecifier, "@vibe-cafe/vibe-usage@latest")
    }

    // MARK: - Environment

    func testMacAppIdentityUsesTheDisplayVersion() {
        XCTAssertEqual(AppConfig.cliIdentityEnvironment["VIBE_USAGE_SURFACE"], "mac-app")
        XCTAssertEqual(AppConfig.cliIdentityEnvironment["VIBE_USAGE_SURFACE_VERSION"], AppConfig.version)
    }

    /// The launcher imports the CLI in-process, so the identity variables it
    /// inherits are the ones the CLI uploads with — on every runtime.
    func testIdentityReachesTheCLIOnEveryRuntime() {
        let base = ["PATH": "/usr/bin:/bin", "VIBE_USAGE_SURFACE": "cli", "HOME": "/Users/test"]
        for kind in [RuntimeDetector.Kind.bundledNode, .systemNode, .bun, .npx] {
            let env = RuntimeDetector.Runtime(kind: kind, executablePath: "/opt/homebrew/bin/node",
                                              launcherPath: launcher).environment(base: base)
            XCTAssertEqual(env["VIBE_USAGE_SURFACE"], "mac-app", "\(kind)")
            XCTAssertEqual(env["VIBE_USAGE_SURFACE_VERSION"], AppConfig.version, "\(kind)")
            XCTAssertEqual(env["HOME"], "/Users/test")
        }
    }

    /// Tools the CLI starts must keep finding the user's Node, not ours.
    func testOnlySystemRuntimesGoFirstOnPath() {
        let base = ["PATH": "/usr/bin:/bin"]
        let bundledEnv = RuntimeDetector.Runtime(kind: .bundledNode, executablePath: bundled,
                                                 launcherPath: launcher).environment(base: base)
        XCTAssertEqual(bundledEnv["PATH"], "/usr/bin:/bin")
        let systemEnv = RuntimeDetector.Runtime(kind: .systemNode, executablePath: "/opt/homebrew/bin/node",
                                                launcherPath: launcher).environment(base: base)
        XCTAssertEqual(systemEnv["PATH"], "/opt/homebrew/bin:/usr/bin:/bin")
        let bunEnv = RuntimeDetector.Runtime(kind: .bun, executablePath: "/Users/test/.bun/bin/bun",
                                             launcherPath: launcher).environment(base: [:])
        XCTAssertEqual(bunEnv["PATH"], "/Users/test/.bun/bin")
    }

    // MARK: - Order

    private final class Calls: @unchecked Sendable {
        var bundled = 0
        var system = 0
        var bun = 0
    }

    private func select(
        prefersSystem: Bool = false,
        bundledStatus: BundledNodeStatus,
        systemNodes: [(path: String, version: String)] = [],
        bunPath: String? = nil,
        calls: Calls = Calls()
    ) async -> RuntimeDetector.Runtime? {
        await RuntimeDetector.select(
            launcherPath: launcher,
            prefersSystem: prefersSystem,
            bundledNode: { calls.bundled += 1; return bundledStatus },
            bundledNodePath: bundled,
            systemNodes: { calls.system += 1; return systemNodes },
            bunPath: { calls.bun += 1; return bunPath }
        )
    }

    func testBundledNodeComesFirstAndNothingElseIsAsked() async {
        let calls = Calls()
        let runtime = await select(bundledStatus: .ok(version: "24.22.3"),
                                   systemNodes: [("/usr/local/bin/node", "22.19.0")],
                                   bunPath: "/opt/homebrew/bin/bun", calls: calls)
        XCTAssertEqual(runtime, .init(kind: .bundledNode, executablePath: bundled,
                                      launcherPath: launcher, version: "24.22.3"))
        XCTAssertEqual(calls.system, 0)
        XCTAssertEqual(calls.bun, 0)
    }

    func testAnUnusableBundledNodeFallsBackToSystemNode() async {
        for status in [BundledNodeStatus.missing, .launchFailed, .killed, .timedOut, .failed] {
            let runtime = await select(bundledStatus: status,
                                       systemNodes: [("/usr/local/bin/node", "22.19.0")],
                                       bunPath: "/opt/homebrew/bin/bun")
            XCTAssertEqual(runtime?.kind, .systemNode, "\(status)")
            XCTAssertEqual(runtime?.executablePath, "/usr/local/bin/node")
            XCTAssertEqual(runtime?.launcherPath, launcher)
        }
    }

    /// Like Windows: Node 22.5+ (built-in SQLite) first, then any Node 20+.
    func testSystemNodePrefers22Point5ThenAccepts20() async {
        let preferred = await select(bundledStatus: .killed, systemNodes: [
            ("/Users/test/.nvm/versions/node/v20.19.0/bin/node", "20.19.0"),
            ("/usr/local/bin/node", "18.20.4"),
            ("/opt/homebrew/bin/node", "24.11.0"),
        ])
        XCTAssertEqual(preferred?.executablePath, "/opt/homebrew/bin/node")

        let accepted = await select(bundledStatus: .killed, systemNodes: [
            ("/usr/local/bin/node", "18.20.4"),
            ("/Users/test/.nvm/versions/node/v20.19.0/bin/node", "20.19.0"),
        ])
        XCTAssertEqual(accepted?.executablePath, "/Users/test/.nvm/versions/node/v20.19.0/bin/node")
    }

    func testBunIsLastAndTooOldNodeIsSkipped() async {
        let runtime = await select(bundledStatus: .missing,
                                   systemNodes: [("/usr/local/bin/node", "18.20.4")],
                                   bunPath: "/opt/homebrew/bin/bun")
        XCTAssertEqual(runtime, .init(kind: .bun, executablePath: "/opt/homebrew/bin/bun", launcherPath: launcher))
        let none = await select(bundledStatus: .killed, systemNodes: [("/usr/local/bin/node", "16.0.0")])
        XCTAssertNil(none)
    }

    /// `cliRuntimePreference = system` never even probes the bundled Node.
    func testTheSupportSwitchSkipsTheBundledNode() async {
        let calls = Calls()
        let runtime = await select(prefersSystem: true, bundledStatus: .ok(version: "24.22.3"),
                                   systemNodes: [("/usr/local/bin/node", "22.19.0")], calls: calls)
        XCTAssertEqual(runtime?.kind, .systemNode)
        XCTAssertEqual(calls.bundled, 0)

        let none = await select(prefersSystem: true, bundledStatus: .ok(version: "24.22.3"))
        XCTAssertNil(none)
    }

    func testThePreferenceIsReadFromTheAppDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RuntimeDetectorTests-\(UUID().uuidString)"))
        XCTAssertFalse(RuntimeDetector.prefersSystemRuntime(defaults))
        defaults.set("bundled", forKey: RuntimeDetector.preferenceKey)
        XCTAssertFalse(RuntimeDetector.prefersSystemRuntime(defaults))
        defaults.set("system", forKey: RuntimeDetector.preferenceKey)
        XCTAssertTrue(RuntimeDetector.prefersSystemRuntime(defaults))
    }

    func testVersionThresholds() {
        XCTAssertTrue(RuntimeDetector.isAtLeast("22.5.0", 22, 5))
        XCTAssertTrue(RuntimeDetector.isAtLeast("24.0.0", 22, 5))
        XCTAssertFalse(RuntimeDetector.isAtLeast("22.4.1", 22, 5))
        XCTAssertTrue(RuntimeDetector.isAtLeast("20.0.0", 20, 0))
        XCTAssertFalse(RuntimeDetector.isAtLeast("19.9.0", 20, 0))
        XCTAssertFalse(RuntimeDetector.isAtLeast("garbage", 20, 0))
    }

    // MARK: - Bundled Node probe

    func testProbeClassifiesTheProcessResult() {
        func classify(_ stdout: String, exit: Int32 = 0, timedOut: Bool = false, signal: Bool = false) -> BundledNodeStatus {
            BundledNodeProbe.classify(.init(stdout: stdout, stderr: "", exitCode: exit,
                                            timedOut: timedOut, terminatedBySignal: signal))
        }
        XCTAssertEqual(classify("v24.22.3"), .ok(version: "24.22.3"))
        XCTAssertEqual(classify("", exit: 9, signal: true), .killed)
        XCTAssertEqual(classify("", exit: 15, timedOut: true, signal: true), .timedOut)
        XCTAssertEqual(classify("v24.22.3", exit: 1), .failed)
        XCTAssertEqual(classify("hello"), .failed)
    }

    /// Real processes: a missing file, a fake node that works, one the system
    /// kills, and one that never answers.
    func testProbeRunsTheExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func script(_ name: String, _ body: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }

        let missing = await BundledNodeProbe.run(directory.appendingPathComponent("node").path)
        XCTAssertEqual(missing, .missing)
        let working = await BundledNodeProbe.run(try script("ok", #"test "$1" = -e && printf v24.22.3"#))
        XCTAssertEqual(working, .ok(version: "24.22.3"))
        let killed = await BundledNodeProbe.run(try script("killed", "kill -9 $$"))
        XCTAssertEqual(killed, .killed)
        let failing = await BundledNodeProbe.run(try script("failing", "exit 3"))
        XCTAssertEqual(failing, .failed)
    }

    func testProbeRunsOncePerPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-probe-once-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = directory.appendingPathComponent("count")
        let node = directory.appendingPathComponent("node")
        try "#!/bin/sh\necho x >> '\(counter.path)'\nprintf v24.22.3\n".write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)

        let probe = BundledNodeProbe()
        async let first = probe.status(path: node.path)
        async let second = probe.status(path: node.path)
        let results = await [first, second]
        let third = await probe.status(path: node.path)
        XCTAssertEqual(results, [.ok(version: "24.22.3"), .ok(version: "24.22.3")])
        XCTAssertEqual(third, .ok(version: "24.22.3"))
        let runs = try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count
        XCTAssertEqual(runs, 1)
    }
}
