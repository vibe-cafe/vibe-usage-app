import Foundation
import Testing
@testable import VibeUsage

struct EgressCheckTests {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// A checker whose trace answers, network and clock are scripted.
    private func checker(
        answer: Box<String?>, calls: Box<[String]>, network: Box<String> = Box("net-a"), clock: Box<Date> = Box(Date(timeIntervalSince1970: 1_000))
    ) -> EgressCheck.Checker {
        EgressCheck.Checker(
            fetch: { host in calls.value.append(host); return answer.value },
            fingerprint: { network.value },
            now: { clock.value }
        )
    }

    private func defaults(enabled: Bool? = nil, requireProxy: Bool = false) -> (UserDefaults, String) {
        let suite = "EgressCheckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if let enabled { defaults.set(enabled, forKey: EgressCheck.enabledKey) }
        if requireProxy { defaults.set(true, forKey: EgressCheck.requireProxyKey) }
        return (defaults, suite)
    }

    @Test
    func traceRegionReadsOnlyATwoLetterLocLine() {
        #expect(EgressCheck.traceRegion("fl=1\nh=chatgpt.com\nip=203.0.113.9\nloc=US\ntls=TLSv1.3\n") == "US")
        #expect(EgressCheck.traceRegion("loc=cn\n") == "CN")
        #expect(EgressCheck.traceRegion("loc=XX\n") == nil)
        #expect(EgressCheck.traceRegion("loc=T1\n") == nil)
        #expect(EgressCheck.traceRegion("loc=USA\n") == nil)
        #expect(EgressCheck.traceRegion("colo=HKG\n") == nil)
        #expect(EgressCheck.traceRegion("") == nil)
    }

    @Test
    func aDirectReadPausesOnAnUnsupportedOrUnknownEgress() async {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        for (region, expected) in [
            ("US", nil), ("SG", nil),
            ("CN", EgressCheck.Paused.Reason.regionUnsupported("CN")),
            ("HK", .regionUnsupported("HK")), ("MO", .regionUnsupported("MO")),
            (nil, .unconfirmed),
        ] as [(String?, EgressCheck.Paused.Reason?)] {
            let calls = Box<[String]>([])
            let check = checker(answer: Box(region), calls: calls)
            do {
                try await EgressCheck.requireDirect(traceHost: "chatgpt.com", defaults: store, checker: check)
                #expect(expected == nil, "\(String(describing: region))")
            } catch let paused as EgressCheck.Paused {
                #expect(paused.reason == expected)
            } catch {
                Issue.record("unexpected \(error)")
            }
            #expect(calls.value == ["chatgpt.com"])
        }
    }

    @Test
    func theTwoSettingsDecideWithoutACheck() async throws {
        let calls = Box<[String]>([])
        let check = checker(answer: Box("CN"), calls: calls)
        let (off, offSuite) = defaults(enabled: false)
        defer { off.removePersistentDomain(forName: offSuite) }
        try await EgressCheck.requireDirect(traceHost: "chatgpt.com", defaults: off, checker: check)

        let (manual, manualSuite) = defaults(requireProxy: true)
        defer { manual.removePersistentDomain(forName: manualSuite) }
        await #expect(throws: EgressCheck.Paused(reason: .proxyNotDetected)) {
            try await EgressCheck.requireDirect(traceHost: "chatgpt.com", defaults: manual, checker: check)
        }
        #expect(calls.value.isEmpty)
        // Always both, so a value inherited from the user's own environment
        // cannot override Settings.
        #expect(EgressCheck.cliEnvironment(off) == ["VIBE_USAGE_EGRESS_CHECK": "0", "VIBE_USAGE_REQUIRE_PROXY": "0"])
        #expect(EgressCheck.cliEnvironment(manual) == ["VIBE_USAGE_EGRESS_CHECK": "1", "VIBE_USAGE_REQUIRE_PROXY": "1"])
        let (plain, plainSuite) = defaults()
        defer { plain.removePersistentDomain(forName: plainSuite) }
        #expect(EgressCheck.cliEnvironment(plain) == ["VIBE_USAGE_EGRESS_CHECK": "1", "VIBE_USAGE_REQUIRE_PROXY": "0"])
        #expect(EgressCheck.isEnabled(plain))
        #expect(!EgressCheck.requiresProxy(plain))
    }

    @Test
    func answersAreKeptPerNetworkTenMinutesWhenSupportedOneMinuteOtherwise() async {
        let answer = Box<String?>("US")
        let calls = Box<[String]>([])
        let network = Box("net-a")
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = Box(start)
        let check = checker(answer: answer, calls: calls, network: network, clock: clock)
        func at(_ minutes: Double) { clock.value = start.addingTimeInterval(minutes * 60) }

        #expect(await check.region(through: "chatgpt.com") == "US")
        at(9.9)
        #expect(await check.region(through: "chatgpt.com") == "US")
        #expect(calls.value.count == 1)
        // Another network (Wi-Fi switched, TUN adapter gone) asks again.
        answer.value = "CN"
        network.value = "net-b"
        #expect(await check.region(through: "chatgpt.com") == "CN")
        #expect(calls.value.count == 2)
        at(10.4)
        #expect(await check.region(through: "chatgpt.com") == "CN")
        #expect(calls.value.count == 2)
        // A paused answer lasts a minute: a proxy turned on is seen soon.
        answer.value = "US"
        at(11)
        #expect(await check.region(through: "chatgpt.com") == "US")
        #expect(calls.value.count == 3)
        at(21.5)
        #expect(await check.region(through: "chatgpt.com") == "US")
        #expect(calls.value.count == 4)
        // Hosts are kept apart.
        #expect(await check.region(through: "api.anthropic.com") == "US")
        #expect(calls.value.last == "api.anthropic.com")
    }

    @Test
    func concurrentReadsShareOneCheck() async {
        let calls = Box<[String]>([])
        let check = EgressCheck.Checker(
            fetch: { host in
                calls.value.append(host)
                try? await Task.sleep(for: .milliseconds(50))
                return "US"
            },
            fingerprint: { "net" }
        )
        async let first = check.region(through: "chatgpt.com")
        async let second = check.region(through: "chatgpt.com")
        let answers = await [first, second]
        #expect(answers == ["US", "US"])
        #expect(calls.value == ["chatgpt.com"])
    }

    @Test
    func codexIsCheckedOnlyWhenItsOwnRouteIsDirect() async throws {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let calls = Box<[String]>([])
        let check = checker(answer: Box("CN"), calls: calls)
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        // Through a proxy: nothing to check.
        for route in [SystemProxy.Route.http(host: "127.0.0.1", port: 7890), .socks(host: "127.0.0.1", port: 7891), .unresolved] {
            try await EgressCheck.checkCodex(url: url, route: { _ in route }, defaults: store, checker: check)
        }
        #expect(calls.value.isEmpty)
        // A relay the user chose in `chatgpt_base_url`: OpenAI sees the relay.
        try await EgressCheck.checkCodex(
            url: URL(string: "https://relay.example.com/backend-api/wham/usage")!,
            route: { _ in .direct }, defaults: store, checker: check
        )
        #expect(calls.value.isEmpty)
        await #expect(throws: EgressCheck.Paused(reason: .regionUnsupported("CN"))) {
            try await EgressCheck.checkCodex(url: url, route: { _ in .direct }, defaults: store, checker: check)
        }
        #expect(calls.value == ["chatgpt.com"])
    }

    @Test
    func claudeIsCheckedThroughTheFirstAnthropicHostThatGoesDirect() async throws {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let calls = Box<[String]>([])
        let check = checker(answer: Box("US"), calls: calls)
        let proxied: SystemProxy.Route = .http(host: "127.0.0.1", port: 7890)
        func run(
            base: [String: String] = [:], settings: [String: String] = [:],
            direct: Set<String> = []
        ) async throws {
            try await EgressCheck.checkClaude(
                base: base, settingsEnvironment: settings,
                routes: { hosts in hosts.map { ($0, direct.contains($0) ? .direct : proxied) } },
                defaults: store, checker: check
            )
        }
        try await run()
        #expect(calls.value.isEmpty)
        // The app's own proxy variables go to Claude Code as they are.
        try await run(base: ["HTTPS_PROXY": "http://127.0.0.1:7890"], direct: Set(SystemProxy.claudeHosts))
        #expect(calls.value.isEmpty)
        try await run(direct: ["claude.ai"])
        #expect(calls.value == ["claude.ai"])
        try await run(direct: Set(SystemProxy.claudeHosts))
        #expect(calls.value == ["claude.ai", "api.anthropic.com"])
        // Which host is asked, without the checker's cache in the way.
        func host(
            base: [String: String] = [:], settings: [String: String] = [:], direct: Set<String> = []
        ) async -> String? {
            await EgressCheck.claudeTraceHost(base: base, settingsEnvironment: settings) { hosts in
                hosts.map { ($0, direct.contains($0) ? .direct : proxied) }
            }
        }
        // The app's own proxy with the user's bypass list: that host goes direct.
        #expect(await host(base: ["HTTPS_PROXY": "http://127.0.0.1:7890", "NO_PROXY": "anthropic.com"])
            == "api.anthropic.com")
        // A proxy set only in Claude Code's own settings.json is a proxy.
        #expect(await host(settings: ["HTTPS_PROXY": "http://127.0.0.1:7890"], direct: Set(SystemProxy.claudeHosts)) == nil)
        // ...and its own bypass list, also past the system proxy, sends a host direct.
        #expect(await host(settings: ["HTTPS_PROXY": "http://127.0.0.1:7890", "no_proxy": "claude.ai"]) == "claude.ai")
        #expect(await host(settings: ["NO_PROXY": ".claude.ai"]) == "claude.ai")
    }

    @Test
    func bypassListsAreReadBroadly() {
        #expect(EgressCheck.bypassMatches(host: "api.anthropic.com", list: "anthropic.com"))
        #expect(EgressCheck.bypassMatches(host: "api.anthropic.com", list: "localhost, .anthropic.com"))
        #expect(EgressCheck.bypassMatches(host: "api.anthropic.com", list: "*.anthropic.com:443"))
        #expect(EgressCheck.bypassMatches(host: "claude.ai", list: "*"))
        #expect(!EgressCheck.bypassMatches(host: "api.anthropic.com", list: "notanthropic.com"))
        #expect(!EgressCheck.bypassMatches(host: "api.anthropic.com", list: ""))
    }

    @Test
    func aPauseIsHandledAsAMissingSourceWithItsOwnReason() {
        let paused = EgressCheck.Paused(reason: .regionUnsupported("CN"))
        #expect(paused.rateLimitFailure == .absent)
        #expect(paused.liveFailure == .egressRegionUnsupported("CN"))
        #expect(EgressCheck.Paused(reason: .unconfirmed).liveFailure == .egressUnconfirmed)
        #expect(EgressCheck.Paused(reason: .proxyNotDetected).liveFailure == .proxyNotDetected)
        #expect(ProviderRateLimit.LiveFailure.egressUnconfirmed.isPause)
        #expect(!ProviderRateLimit.LiveFailure.endpointUnreachable.isPause)
    }

    @Test
    func theTraceSessionIsDirectAndKeepsNothing() {
        let configuration = EgressCheck.traceConfiguration()
        let proxies = configuration.connectionProxyDictionary ?? [:]
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"] {
            #expect(proxies[key] as? Int == 0, "\(key)")
        }
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.timeoutIntervalForResource == EgressCheck.timeout)
    }

    @Test
    func theNetworkFingerprintIgnoresOrderAndFollowsTheAddresses() {
        let base = EgressCheck.fingerprint(of: ["en0|2|192.168.1.20", "en0|30|2001:db8::1"])
        #expect(EgressCheck.fingerprint(of: ["en0|30|2001:db8::1", "en0|2|192.168.1.20"]) == base)
        #expect(EgressCheck.fingerprint(of: ["en0|2|192.168.1.20", "en0|30|2001:db8::1", "utun4|2|198.18.0.1"]) != base)
        #expect(base.count == 16)
        #expect(!EgressCheck.networkFingerprint().isEmpty)
    }

    // MARK: - What the cards and Settings say

    @Test
    func pausedCardsSayWhyInOneLine() {
        let line = { RateLimitCardView.liveFailureText($0, provider: .codex) }
        #expect(line(.egressRegionUnsupported("CN")) == "网络出口在中国大陆，已暂停读取")
        #expect(line(.egressRegionUnsupported("HK")) == "网络出口在香港，已暂停读取")
        #expect(line(.egressRegionUnsupported("MO")) == "网络出口在澳门，已暂停读取")
        #expect(line(.egressRegionUnsupported("")) == "网络出口不在支持地区，已暂停读取")
        #expect(line(.egressUnconfirmed) == "无法确认网络出口，已暂停读取")
        #expect(line(.proxyNotDetected) == "未检测到代理，已暂停读取")

        let empty = ProviderRateLimit(provider: .claudeCode, status: .noData, liveFailure: .egressRegionUnsupported("CN"))
        #expect(RateLimitCardView.emptyStateText(for: empty, isDetected: true) == "网络出口在中国大陆，已暂停读取")
        var kept = ProviderRateLimit(provider: .codex, status: .ok, liveFailure: .egressUnconfirmed)
        kept.source = .cache
        #expect(RateLimitCardView.staleDataNote(for: kept) == "来源：缓存 · 无法确认网络出口，已暂停读取")

        let product = QuotaProduct(provider: .codex, availability: .ready, isDetected: true)
        let status = { (failure: ProviderRateLimit.LiveFailure) in
            SettingsQuotaStatus.status(for: product, zCodeKeyConfigured: false,
                warningSnapshot: ProviderRateLimit(provider: .codex, status: .noData, liveFailure: failure)).text
        }
        #expect(status(.egressRegionUnsupported("CN")) == "出口受限，已暂停")
        #expect(status(.egressUnconfirmed) == "出口未确认")
        #expect(status(.proxyNotDetected) == "无代理，已暂停")
        // Numbers kept on the card while paused: Settings still says paused.
        var keptOK = ProviderRateLimit(provider: .codex, status: .ok, liveFailure: .egressUnconfirmed)
        keptOK.source = .cache
        #expect(SettingsQuotaStatus.status(for: product, zCodeKeyConfigured: false, warningSnapshot: keptOK).text == "出口未确认")
    }

    @Test
    func theCLIPauseReasonBecomesTheCardsReason() throws {
        let json = """
        {"schemaVersion":1,"products":[
          {"id":"antigravity","status":"unsupported","meters":[],"fetchedAt":"2026-11-24T12:00:00.000Z","source":"live",
           "message":"Paused","pauseReason":"egressRegionUnsupported","egressRegion":"HK"},
          {"id":"cursor","status":"unsupported","meters":[],"fetchedAt":"2026-11-24T12:00:00.000Z","source":"live",
           "pauseReason":"somethingNew"},
          {"id":"grok","status":"unsupported","meters":[],"fetchedAt":"2026-11-24T12:00:00.000Z","source":"live",
           "pauseReason":"egressUnconfirmed"}
        ]}
        """
        let snapshots = try QuotaCLIBridge.snapshots(from: QuotaCLIBridge.decode(json))
        #expect(snapshots[0].status == .noData)
        #expect(snapshots[0].liveFailure == .egressRegionUnsupported("HK"))
        #expect(snapshots[1].liveFailure == nil)
        #expect(snapshots[2].liveFailure == .egressUnconfirmed)
        #expect(QuotaCLIBridge.pauseFailure(reason: "proxyNotDetected", region: nil) == .proxyNotDetected)
        #expect(QuotaCLIBridge.pauseFailure(reason: "egressRegionUnsupported", region: "cn") == .egressRegionUnsupported(""))
    }

    // MARK: - The coordinator

    @Test @MainActor
    func aPausedCodexReadKeepsWhatIsOnScreenOrSaysWhy() async {
        let appState = AppState()
        let paused = EgressCheck.Paused(reason: .regionUnsupported("CN"))
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: { throw paused },
            loadCodexCache: { nil },
            readCodexFallback: { ProviderRateLimit(provider: .codex, status: .noData) }
        )
        await coordinator.refreshCodex()
        let card = appState.rateLimits.first { $0.provider == .codex }
        #expect(card?.status == .noData)
        #expect(card?.liveFailure == .egressRegionUnsupported("CN"))

        let reading = ProviderRateLimit(
            provider: .codex,
            meters: [RateLimitMeter(id: "5h", label: "5h", window: RateLimitWindow(utilization: 30))],
            status: .ok, fetchedAt: Date(), source: .live
        )
        appState.rateLimits = [reading]
        let again = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: { throw paused },
            loadCodexCache: { nil },
            readCodexFallback: { ProviderRateLimit(provider: .codex, status: .noData) }
        )
        await again.refreshCodex()
        let kept = appState.rateLimits.first { $0.provider == .codex }
        #expect(kept?.status == .ok)
        #expect(kept?.meters.first?.window.utilization == 30)
        #expect(kept?.liveFailure == .egressRegionUnsupported("CN"))
    }

    @Test @MainActor
    func aPausedReadIsTriedAgainAtTheNextOpen() async {
        let appState = AppState()
        var fetches = 0
        var paused = true
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: {
                fetches += 1
                if paused { throw EgressCheck.Paused(reason: .regionUnsupported("CN")) }
                return ProviderRateLimit(
                    provider: .codex,
                    meters: [RateLimitMeter(id: "5h", label: "5h", window: RateLimitWindow(utilization: 10))],
                    status: .ok, fetchedAt: Date(), source: .live
                )
            },
            loadCodexCache: { nil },
            readCodexFallback: { ProviderRateLimit(provider: .codex, status: .noData) }
        )
        await coordinator.refreshCodexIfNeeded()
        paused = false
        // Within the usual minute: not skipped, since the last read was paused.
        await coordinator.refreshCodexIfNeeded()
        #expect(fetches == 2)
        #expect(appState.rateLimits.first { $0.provider == .codex }?.status == .ok)
        await coordinator.refreshCodexIfNeeded()
        #expect(fetches == 2)
    }

    @Test @MainActor
    func aPausedClaudeReadIsNotTakenForASessionWithoutPlanLimits() async {
        let appState = AppState()
        let coordinator = RateLimitCoordinator(
            appState: appState,
            claudeNonessentialTrafficDisabled: { false },
            fetchClaudeLive: { throw EgressCheck.Paused(reason: .unconfirmed) },
            loadClaudeCache: { nil }
        )
        await coordinator.refreshClaude()
        let card = appState.rateLimits.first { $0.provider == .claudeCode }
        #expect(card?.status == .noData)
        #expect(card?.emptyReason == nil)
        #expect(card?.liveFailure == .egressUnconfirmed)
    }
}
