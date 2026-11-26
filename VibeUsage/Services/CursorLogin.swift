import AppKit
import Foundation
import Security
import SystemConfiguration

// Cursor separate sign-in (「单独登录 Cursor」), approved by the maintainer on
// 2026-11-25 (workspace notes 《Cursor-加密凭据-方案》). Cursor 3.27+ encrypts
// the login it keeps and we do not decrypt it; instead the user signs in to
// Cursor once more, for Vibe Usage, through the browser sign-in Cursor's own
// CLI uses. Every request (sign-in poll, profile, renewal, usage reads) is
// made by the shared CLI (`vibe-usage login cursor`, vibe-cafe/vibe-usage#210)
// with the system proxy the app hands it; the app only opens the browser,
// keeps what the CLI printed in its own Keychain item, and hands it back on
// stdin (`--cursor-login-stdin`) on every sync and quota read. Nothing of
// Cursor's own (state.vscdb, Local State, its Keychain items) is read here.

// MARK: - Record

/// The Cursor sign-in the CLI printed (`login cursor --json`), kept verbatim
/// and handed back unchanged. The app reads only what it shows or schedules
/// by (the account's email, the expiry); the tokens inside are never logged,
/// shown, put in diagnostics, the environment or argv.
struct CursorLoginRecord: Equatable, Sendable {
    let data: Data
    let email: String?
    let expiresAt: Date?
    /// Cursor ended the sign-in: the tokens are gone, only the email is left.
    let rejectedAt: Date?

    var hasCredential: Bool { rejectedAt == nil }

    static func parse(_ data: Data) -> CursorLoginRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object)
    }

    /// A credential the CLI printed (it has `accessToken` and `userId`), or
    /// the record left after Cursor ended one (`rejectedAt`). Nil otherwise.
    static func parse(_ object: [String: Any]) -> CursorLoginRecord? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        let email = (object["email"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0.count > 320 ? nil : $0 }
        if let rejectedAt = date(object["rejectedAt"]) {
            return CursorLoginRecord(data: data, email: email, expiresAt: nil, rejectedAt: rejectedAt)
        }
        guard let token = object["accessToken"] as? String, !token.isEmpty,
              let user = object["userId"] as? String, !user.isEmpty
        else { return nil }
        return CursorLoginRecord(data: data, email: email, expiresAt: date(object["expiresAt"]), rejectedAt: nil)
    }

    /// What is kept after Cursor ended the sign-in: no tokens, only what the
    /// Settings row shows. The same shape as the CLI's own record.
    static func ended(email: String?, at date: Date) -> CursorLoginRecord {
        var object: [String: Any] = ["version": 1, "rejectedAt": iso8601(date)]
        if let email { object["email"] = email }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return CursorLoginRecord(data: data, email: email, expiresAt: nil, rejectedAt: date)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Keychain

protocol CursorLoginStoring: Sendable {
    func load() throws -> Data?
    /// `nil` deletes the item.
    func store(_ data: Data?) throws
}

/// Vibe Usage's own Keychain item, next to the ZCode keys
/// (`ZCodeAPIKeyStore`): same service, same accessibility. Only this app
/// (signed with our certificate) reads it without a prompt.
struct KeychainCursorLoginStore: CursorLoginStoring {
    private static let account = "cursor-login"
    private let service: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.service = VibeUsageKeychain.service(environment: environment)
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func load() throws -> Data? {
        var result: CFTypeRef?
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ZCodeAPIKeyStoreError.keychain(status) }
        return result as? Data
    }

    func store(_ data: Data?) throws {
        guard let data, !data.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ZCodeAPIKeyStoreError.keychain(status)
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw ZCodeAPIKeyStoreError.keychain(updateStatus) }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw ZCodeAPIKeyStoreError.keychain(addStatus) }
    }
}

// MARK: - CLI

enum CursorSignInFailure: Equatable, Sendable {
    /// 5 minutes passed without a confirmation.
    case timedOut
    /// The CLI could not reach Cursor while waiting.
    case network
    /// The user's proxy settings cannot be followed: nothing was sent.
    case proxy
    /// The CLI asked to open something other than Cursor's sign-in page.
    case unexpectedURL
    /// The system proxy changed while waiting: the CLI was started with the
    /// old one, so it is stopped rather than left polling on a stale route.
    case proxyChanged
    case noRuntime
    case failed

    var text: String {
        switch self {
        case .timedOut: "5 分钟内没有确认，已取消登录"
        case .network: "连不上 Cursor，请检查网络和代理后重试"
        case .proxy: "无法按你的代理设置连接 Cursor，未发送任何请求"
        case .unexpectedURL: "登录地址不对，已取消"
        case .proxyChanged: "代理设置变了，请重新登录"
        case .noRuntime: "没有可用的 Node.js 或 Bun"
        case .failed: "Cursor 没有完成登录，请重试"
        }
    }
}

enum CursorSignInResult: Equatable, Sendable {
    case credential(Data)
    case failed(CursorSignInFailure)
}

enum CursorRenewalResult: Equatable, Sendable {
    case renewed(Data)
    /// Cursor ended the sign-in (`shouldLogout`, rejected, another account).
    case expired
    /// Did not complete (network, Cursor's server, proxy, no runtime): try
    /// again later with the current one.
    case incomplete
}

/// The three CLI commands the sign-in needs. The default runs the shared CLI
/// through the chosen runtime with the system proxy (`ProcessCursorLoginCLI`).
protocol CursorLoginCLI: Sendable {
    /// `vibe-usage --version`, or nil when the CLI does not start.
    func version() async -> String?
    /// `login cursor --json`: `openBrowser` gets the page to open (already
    /// checked to be Cursor's sign-in page). Cancelling the task stops it.
    func signIn(openBrowser: @escaping @Sendable (URL) -> Void) async -> CursorSignInResult
    /// `login cursor --refresh --json --cursor-login-stdin`.
    func renew(_ credential: Data) async -> CursorRenewalResult
}

struct ProcessCursorLoginCLI: CursorLoginCLI {
    /// One JSON object per line (`cursor-login.js` `writeJsonLine`).
    struct Event: Sendable {
        var event: String
        var url: String?
        var code: String?
        var credential: Data?

        init?(line: String) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let event = object["event"] as? String
            else { return nil }
            self.event = event
            url = object["url"] as? String
            code = object["code"] as? String
            credential = (object["credential"] as? [String: Any])
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        }
    }

    func version() async -> String? {
        guard let output = try? await CLIBridge.runCLI(args: ["--version"], timeout: 20) else { return nil }
        return ClaudeUsageProbe.versionNumber(in: output)
    }

    func signIn(openBrowser: @escaping @Sendable (URL) -> Void) async -> CursorSignInResult {
        let outcome = OutcomeBox<CursorSignInResult>()
        let ran = await Self.run(["login", "cursor", "--json"], standardInput: nil, timeout: 6 * 60) { event in
            switch event.event {
            case "open":
                guard let url = event.url.flatMap(CursorLogin.signInPage(_:)) else {
                    outcome.set(.failed(.unexpectedURL))
                    return false
                }
                openBrowser(url)
                return true
            case "credential":
                outcome.set(event.credential.map(CursorSignInResult.credential) ?? .failed(.failed))
                return true
            case "error":
                outcome.set(.failed(Self.failure(code: event.code)))
                return true
            default:
                return true
            }
        }
        guard ran else { return .failed(.noRuntime) }
        return outcome.value ?? .failed(.failed)
    }

    func renew(_ credential: Data) async -> CursorRenewalResult {
        let outcome = OutcomeBox<CursorRenewalResult>()
        _ = await Self.run(
            ["login", "cursor", "--refresh", "--json", "--cursor-login-stdin"],
            standardInput: credential, timeout: 60
        ) { event in
            switch event.event {
            case "credential":
                outcome.set(event.credential.map(CursorRenewalResult.renewed) ?? .incomplete)
            case "expired":
                outcome.set(.expired)
            case "error":
                outcome.set(.incomplete)
            default:
                break
            }
            return true
        }
        return outcome.value ?? .incomplete
    }

    nonisolated static func failure(code: String?) -> CursorSignInFailure {
        switch code {
        case "timeout": .timedOut
        case "network": .network
        case "proxy": .proxy
        default: .failed
        }
    }

    /// Runs the command with the system proxy; stdout is read from a pipe,
    /// line by line, so a credential in it never reaches the disk, a log or
    /// an error message. False when no runtime could start the CLI.
    private static func run(
        _ command: [String],
        standardInput: Data?,
        timeout: TimeInterval,
        onEvent: @escaping @Sendable (Event) -> Bool
    ) async -> Bool {
        guard let runtime = await RuntimeDetector.detect() else { return false }
        let environment = await SystemProxy.cliEnvironment(
            base: runtime.environment(base: ProcessInfo.processInfo.environment)
        )
        do {
            _ = try await CLIProcessRunner.run(
                executable: runtime.executablePath,
                arguments: runtime.arguments(command),
                environment: environment,
                timeout: timeout,
                standardInput: standardInput,
                onStdoutLine: { line in Event(line: line).map(onEvent) ?? true }
            )
            return true
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }

    private final class OutcomeBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var value: Value? { lock.withLock { stored } }
        func set(_ value: Value) { lock.withLock { stored = value } }
    }
}

// MARK: - State

enum CursorLoginPhase: Equatable {
    case signedOut
    /// Waiting for the user to confirm in the browser.
    case waiting
    case signedIn(email: String?)
    /// Cursor ended it, or it lapsed: sign in again.
    case expired(email: String?)

    var isExpired: Bool {
        if case .expired = self { return true }
        return false
    }
}

/// The Cursor sign-in Vibe Usage keeps: sign-in, sign-out, renewal, and the
/// record each CLI run gets on stdin.
@MainActor
@Observable
final class CursorLogin {
    static let shared = CursorLogin()

    /// The first CLI release with `login cursor` (vibe-cafe/vibe-usage#210).
    nonisolated static let minimumCLIVersion = [0, 15, 10]
    /// Renew this long before expiry (the CLI's `REFRESH_LEAD_MS`).
    nonisolated static let renewalLead: TimeInterval = 7 * 24 * 3600
    /// After a renewal that did not complete, wait this long (`REFRESH_HOLD_MS`).
    nonisolated static let renewalHold: TimeInterval = 6 * 3600

    private(set) var record: CursorLoginRecord?
    private(set) var isWaiting = false
    /// Why the last sign-in did not complete; cleared by the next attempt.
    private(set) var errorText: String?
    /// Whether the CLI the app runs has `login cursor`; nil until checked.
    private(set) var cliSupportsSignIn: Bool?

    /// After the user signed in (`true`) or out (`false`); not after a renewal.
    @ObservationIgnored var onAccountChange: (@MainActor (Bool) async -> Void)?

    @ObservationIgnored private let store: CursorLoginStoring
    @ObservationIgnored private let cli: CursorLoginCLI
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let watchProxy: ProxyChangeWatch
    /// Stops the proxy watch of the sign-in in progress.
    @ObservationIgnored private var stopProxyWatch: (@MainActor () -> Void)?
    /// Changes on every sign-in and sign-out, so a renewal that finishes
    /// afterwards never writes back over the user's choice.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var renewal: (task: Task<Renewal, Never>, generation: Int)?
    @ObservationIgnored private var renewalHeldUntil: Date?
    /// The record the last renewal produced (due, or after a rejection),
    /// until Cursor is seen accepting it (`noteAccepted`): a rejection of it
    /// ends the sign-in without another renewal (`renewAfterRejection`).
    @ObservationIgnored private var lastRenewal: CursorLoginRecord?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var lastSupportCheck: Date?
    @ObservationIgnored private var loaded = false
    /// The Keychain could not be read (locked, a prompt cancelled): read
    /// again at the next CLI run instead of treating it as no sign-in for
    /// the rest of the session.
    @ObservationIgnored private var loadFailed = false

    init(
        store: CursorLoginStoring = KeychainCursorLoginStore(),
        cli: CursorLoginCLI = ProcessCursorLoginCLI(),
        now: @escaping @Sendable () -> Date = Date.init,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        watchProxy: @escaping ProxyChangeWatch = SystemProxyWatch.start
    ) {
        self.store = store
        self.cli = cli
        self.now = now
        self.openURL = openURL
        self.watchProxy = watchProxy
    }

    /// Reads our Keychain item once (at launch); later reads use memory. A
    /// read that failed is tried again at the next CLI run.
    func load() {
        guard !loaded || loadFailed else { return }
        loaded = true
        do {
            record = try store.load().flatMap(CursorLoginRecord.parse)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    var phase: CursorLoginPhase {
        if isWaiting { return .waiting }
        guard let record else { return .signedOut }
        guard record.hasCredential, !isPastExpiry(record) else { return .expired(email: record.email) }
        return .signedIn(email: record.email)
    }

    /// The Settings row offers sign-in once the CLI is known to have it, and
    /// always while there is a sign-in to show or end.
    var isAvailable: Bool { cliSupportsSignIn == true || record != nil }

    /// Signed out or ended, with sign-in on offer.
    var needsSignIn: Bool {
        guard isAvailable else { return false }
        switch phase {
        case .signedOut, .expired: return true
        case .waiting, .signedIn: return false
        }
    }

    /// The sign-in existed and Cursor ended it.
    var hasEnded: Bool { record.map { !$0.hasCredential } ?? false }

    // MARK: CLI support

    /// Asks the CLI for its version (no network request beyond the launcher's
    /// usual registry check). A yes is kept; a no is asked again after a minute.
    func checkCLISupport() async {
        guard cliSupportsSignIn != true else { return }
        if let last = lastSupportCheck, now().timeIntervalSince(last) < 60 { return }
        lastSupportCheck = now()
        guard let version = await cli.version() else { return }
        if Self.supportsSignIn(version: version) { cliSupportsSignIn = true }
        else if cliSupportsSignIn != true { cliSupportsSignIn = false }
    }

    /// Cursor answered a live read made with `record` (numbers, or a live
    /// answer without a window): a later rejection of it is renewed again.
    func noteAccepted(_ record: CursorLoginRecord) {
        if lastRenewal == record { lastRenewal = nil }
    }

    /// A quota answer carrying `signIn` comes from a CLI that has the command.
    func noteCLISupportsSignIn() {
        cliSupportsSignIn = true
    }

    nonisolated static func supportsSignIn(version: String) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<minimumCLIVersion.count {
            let part = index < parts.count ? parts[index] : 0
            if part != minimumCLIVersion[index] { return part > minimumCLIVersion[index] }
        }
        return true
    }

    // MARK: Sign-in

    /// Exactly Cursor's sign-in page, as the CLI builds it; anything else is
    /// not opened.
    nonisolated static func signInPage(_ text: String) -> URL? {
        guard let components = URLComponents(string: text),
              components.scheme == "https",
              components.host == "cursor.com",
              components.port == nil,
              components.user == nil, components.password == nil,
              components.path == "/loginDeepControl",
              let url = components.url
        else { return nil }
        return url
    }

    func signIn() {
        guard !isWaiting, isAvailable else { return }
        errorText = nil
        isWaiting = true
        let cli = self.cli
        let openURL = self.openURL
        // The CLI follows the proxy it was started with for up to 5 minutes.
        stopProxyWatch = watchProxy { [weak self] in self?.proxyChangedWhileWaiting() }
        signInTask = Task { [weak self] in
            let result = await cli.signIn { url in
                Task { @MainActor in openURL(url) }
            }
            guard !Task.isCancelled else { return }
            await self?.finishSignIn(result)
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        stopProxyWatch?()
        stopProxyWatch = nil
        isWaiting = false
    }

    private func proxyChangedWhileWaiting() {
        guard isWaiting else { return }
        cancelSignIn()
        errorText = CursorSignInFailure.proxyChanged.text
    }

    private func finishSignIn(_ result: CursorSignInResult) async {
        signInTask = nil
        stopProxyWatch?()
        stopProxyWatch = nil
        defer { isWaiting = false }
        switch result {
        case .failed(let failure):
            errorText = failure.text
        case .credential(let data):
            guard let next = CursorLoginRecord.parse(data), next.hasCredential else {
                errorText = CursorSignInFailure.failed.text
                return
            }
            do {
                try store.store(next.data)
            } catch {
                errorText = "登录成功，但没能保存，请重试"
                return
            }
            record = next
            generation &+= 1
            renewalHeldUntil = nil
            isWaiting = false
            await onAccountChange?(true)
        }
    }

    /// Forgets the sign-in here. Cursor keeps its side of it until it lapses
    /// or the user revokes it on cursor.com (the confirmation says how).
    func signOut() {
        cancelSignIn()
        do {
            try store.store(nil)
        } catch {
            errorText = "无法删除钥匙串里的登录"
            return
        }
        record = nil
        errorText = nil
        generation &+= 1
        renewalHeldUntil = nil
        let onAccountChange = onAccountChange
        Task { await onAccountChange?(false) }
    }

    // MARK: Renewal and CLI runs

    private enum Renewal {
        case renewed(CursorLoginRecord)
        case ended
        /// Not renewed (held, or it did not complete); the record to keep using.
        case kept(CursorLoginRecord)
    }

    enum RejectionOutcome: Equatable {
        /// Renewed: run again with this one.
        case renewed(CursorLoginRecord)
        /// Cursor ended it (now recorded): sign in again.
        case ended
        /// The renewal did not complete or is on hold.
        case notRenewed
    }

    private func isPastExpiry(_ record: CursorLoginRecord) -> Bool {
        record.expiresAt.map { $0 <= now() } ?? false
    }

    private func isDue(_ record: CursorLoginRecord) -> Bool {
        record.expiresAt.map { $0.timeIntervalSince(now()) <= Self.renewalLead } ?? false
    }

    /// What this CLI run (sync or quota read) gets on stdin, renewed first
    /// when it is within 7 days of expiry. Nil when there is no sign-in. After
    /// Cursor ended it, the token-free record is still handed over: the CLI
    /// takes it as a sign-in that exists but cannot be used, reads nothing
    /// for Cursor and says so, instead of falling back to another login on
    /// this Mac (Cursor's own, or the CLI's file), which may be another
    /// account. Signing in again, or 「退出」, ends that.
    func credentialForCLI() async -> CursorLoginRecord? {
        if loadFailed { load() }
        guard let current = record else { return nil }
        guard current.hasCredential, isDue(current) else { return current }
        switch await renew(current) {
        case .renewed(let next): return next
        case .ended: return record
        case .kept(let kept): return kept
        }
    }

    /// A CLI run said Cursor rejected `passed` (or that it lapsed). Renew it
    /// once, as the CLI does for a sign-in it stores itself; when the sign-in
    /// that renewal produced is rejected too, Cursor no longer takes it and it
    /// ends without another request. Called at most once per run.
    func renewAfterRejection(of passed: CursorLoginRecord) async -> RejectionOutcome {
        guard passed.hasCredential, let current = record, current.hasCredential else { return .ended }
        // Renewed by another run, or signed in again, meanwhile.
        guard current == passed else { return .renewed(current) }
        if lastRenewal == current {
            markEnded(current)
            return .ended
        }
        switch await renew(current) {
        case .renewed(let next):
            return .renewed(next)
        case .ended: return .ended
        case .kept: return .notRenewed
        }
    }

    /// One renewal at a time; concurrent runs wait for the one in flight.
    private func renew(_ current: CursorLoginRecord) async -> Renewal {
        if let renewal, renewal.generation == generation {
            return await renewal.task.value
        }
        if let held = renewalHeldUntil, held > now() { return .kept(current) }
        let startedGeneration = generation
        let cli = self.cli
        let task = Task { @MainActor [weak self] () -> Renewal in
            let result = await cli.renew(current.data)
            return self?.apply(result, to: current, generation: startedGeneration) ?? .kept(current)
        }
        renewal = (task, startedGeneration)
        let outcome = await task.value
        if renewal?.generation == startedGeneration { renewal = nil }
        return outcome
    }

    private func apply(_ result: CursorRenewalResult, to current: CursorLoginRecord, generation started: Int) -> Renewal {
        // Signed out or in again meanwhile: the user's choice wins, the
        // renewed token is dropped.
        guard generation == started, record == current else {
            if let record, record.hasCredential { return .kept(record) }
            return .ended
        }
        switch result {
        case .renewed(let data):
            guard let next = CursorLoginRecord.parse(data), next.hasCredential else {
                renewalHeldUntil = now().addingTimeInterval(Self.renewalHold)
                return .kept(current)
            }
            // Kept in memory for this session even if the Keychain write fails.
            try? store.store(next.data)
            record = next
            renewalHeldUntil = nil
            lastRenewal = next
            return .renewed(next)
        case .expired:
            markEnded(current)
            return .ended
        case .incomplete:
            renewalHeldUntil = now().addingTimeInterval(Self.renewalHold)
            return .kept(current)
        }
    }
}

extension CursorLogin {
    /// Cursor ended the sign-in: keep only what the Settings row shows.
    fileprivate func markEnded(_ current: CursorLoginRecord) {
        let ended = CursorLoginRecord.ended(email: current.email, at: now())
        try? store.store(ended.data)
        record = ended
    }

    /// For callers outside the main actor (`SyncEngine`, `QuotaCLIBridge`).
    nonisolated static func credentialForCLIRun() async -> CursorLoginRecord? {
        await shared.credentialForCLI()
    }
}

// MARK: - Proxy watch

/// Starts watching the system proxy settings; the closure it returns stops
/// the watch. `onChange` runs on the main actor at most once.
typealias ProxyChangeWatch = @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)

/// Watches `State:/Network/Global/Proxies` (System Settings, or a proxy client
/// turning its system proxy on or off) and reports a change of the settings
/// `CFNetworkCopySystemProxySettings` returns. Nothing is resolved or sent.
@MainActor
final class SystemProxyWatch {
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private var onChange: (@MainActor () -> Void)?
    private let initial: NSDictionary?

    static let start: ProxyChangeWatch = { onChange in
        let watch = SystemProxyWatch(onChange: onChange)
        return { watch.stop() }
    }

    private init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        initial = Self.settings()
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let watch = Unmanaged<SystemProxyWatch>.fromOpaque(info).takeUnretainedValue()
            // The source is on the main run loop.
            MainActor.assumeIsolated { watch.changed() }
        }
        guard let store = SCDynamicStoreCreate(nil, "ai.vibecafe.vibe-usage.cursor-login" as CFString, callback, &context)
        else { return }
        SCDynamicStoreSetNotificationKeys(store, [SCDynamicStoreKeyCreateProxies(nil)] as CFArray, nil)
        if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
        }
        self.store = store
    }

    private static func settings() -> NSDictionary? {
        CFNetworkCopySystemProxySettings()?.takeRetainedValue() as NSDictionary?
    }

    private func changed() {
        guard onChange != nil, Self.settings() != initial else { return }
        let notify = onChange
        stop()
        notify?()
    }

    /// Must run before the watch is released: the callback holds it unretained.
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        store = nil
        onChange = nil
    }
}
