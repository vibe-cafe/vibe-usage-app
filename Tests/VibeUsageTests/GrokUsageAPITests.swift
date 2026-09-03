import Foundation
import Testing
@testable import VibeUsage

struct GrokUsageAPITests {

    // MARK: - Credits payload

    @Test
    func parsesWeeklyCreditsConfig() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000) // 2026-08-30
        let json = """
        {
          "config": {
            "creditUsagePercent": 9.0,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-08-27T06:44:52.255770+00:00",
              "end": "2026-09-03T06:44:52.255770+00:00"
            },
            "onDemandCap": { "val": 0 },
            "onDemandUsed": { "val": 0 },
            "isUnifiedBillingUser": true
          },
          "subscriptionTier": "SuperGrok Plus"
        }
        """
        let snapshot = try #require(GrokUsageAPI.parseCreditsResponse(Data(json.utf8), now: now))

        #expect(snapshot.status == .ok)
        #expect(snapshot.provider == .grok)
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay?.utilization == 9)
        #expect(snapshot.sevenDay?.windowDuration == TimeInterval(7 * 86_400))
        #expect(snapshot.planLabel == "SuperGrok Plus")
        #expect(snapshot.extraUsage == nil)
        #expect(snapshot.dataAsOf == now)
    }

    /// proto3 omits default scalars. A current period with no percent is 0%,
    /// not "no data".
    @Test
    func omittedPercentOnCurrentPeriodIsZeroUsage() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let json = """
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-08-27T06:44:52Z",
              "end": "2026-09-03T06:44:52Z"
            }
          }
        }
        """
        let snapshot = try #require(GrokUsageAPI.parseCreditsResponse(Data(json.utf8), now: now))
        #expect(snapshot.status == .ok)
        #expect(snapshot.sevenDay?.utilization == 0)
    }

    @Test
    func expiredPeriodReportsNoData() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000) // after 2026-09-03
        let json = """
        {
          "config": {
            "creditUsagePercent": 100,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-08-27T06:44:52Z",
              "end": "2026-09-03T06:44:52Z"
            }
          }
        }
        """
        let snapshot = try #require(GrokUsageAPI.parseCreditsResponse(Data(json.utf8), now: now))
        #expect(snapshot.status == .noData)
        #expect(snapshot.sevenDay == nil)
    }

    @Test @MainActor
    func monthlyPeriodSetsThirtyDayDuration() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let json = """
        {
          "config": {
            "creditUsagePercent": 12,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_MONTHLY",
              "start": "2026-08-01T00:00:00Z",
              "end": "2026-09-01T00:00:00Z"
            }
          }
        }
        """
        let snapshot = try #require(GrokUsageAPI.parseCreditsResponse(Data(json.utf8), now: now))
        #expect(snapshot.sevenDay?.windowDuration == TimeInterval(31 * 86_400))
        #expect(RateLimitCardView.longWindowLabel(for: snapshot, window: snapshot.sevenDay!) == "30d")
    }

    @Test
    func onDemandCapBecomesExtraUsageInDollars() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let json = """
        {
          "config": {
            "creditUsagePercent": 5,
            "currentPeriod": {
              "start": "2026-08-27T00:00:00Z",
              "end": "2026-09-03T00:00:00Z"
            },
            "onDemandCap": { "val": 2000 },
            "onDemandUsed": { "val": 250 }
          }
        }
        """
        let snapshot = try #require(GrokUsageAPI.parseCreditsResponse(Data(json.utf8), now: now))
        #expect(snapshot.extraUsage?.isEnabled == true)
        #expect(snapshot.extraUsage?.spend == 2.5)
        #expect(snapshot.extraUsage?.limit == 20)
    }

    @Test
    func rejectsPayloadWithoutConfigOrCreditsFields() {
        let json = #"{ "detail": "Something went wrong" }"#
        #expect(GrokUsageAPI.parseCreditsResponse(Data(json.utf8)) == nil)
    }

    @Test
    func fallsBackToDeprecatedUsedOverMonthlyLimit() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let json = """
        {
          "config": {
            "used": { "val": 2500 },
            "monthlyLimit": { "val": 10000 },
            "billingPeriodEnd": "2026-09-03T00:00:00Z"
          }
        }
        """
        let snapshot = try #require(GrokUsageAPI.parseCreditsResponse(Data(json.utf8), now: now))
        #expect(snapshot.sevenDay?.utilization == 25)
    }

    @Test
    func emptyCentObjectIsZero() {
        #expect(GrokUsageAPI.centsValue(["unused": 1]) == 0)
        #expect(GrokUsageAPI.centsValue(["val": 42]) == 42)
    }

    // MARK: - Settings plan label

    @Test
    func readsDisplayTierFromSettings() throws {
        let json = #"{ "subscription_tier_display": "SuperGrok Heavy" }"#
        #expect(GrokUsageAPI.parseSettingsPlanLabel(Data(json.utf8)) == "SuperGrok Heavy")
    }

    @Test
    func titleCasesLowercasePlanTokens() {
        #expect(GrokUsageAPI.formatPlanLabel("supergrok") == "Supergrok")
        #expect(GrokUsageAPI.formatPlanLabel("SuperGrok Plus") == "SuperGrok Plus")
        #expect(GrokUsageAPI.formatPlanLabel("") == nil)
    }

    // MARK: - auth.json

    @Test
    func prefersAuthXAIEntryOverLegacySession() throws {
        let json = """
        {
          "https://accounts.x.ai/sign-in": {
            "key": "legacy-token",
            "user_id": "legacy-user"
          },
          "https://auth.x.ai::client-id": {
            "key": "oidc-token",
            "user_id": "user-123",
            "expires_at": "2099-01-01T00:00:00Z"
          }
        }
        """
        let auth = try #require(GrokUsageAPI.parseAuthFile(Data(json.utf8)))
        #expect(auth.accessToken == "oidc-token")
        #expect(auth.userID == "user-123")
    }

    @Test
    func rejectsAuthFileWithoutSessionKey() {
        let json = #"{ "https://auth.x.ai::client": { "email": "a@b.c" } }"#
        #expect(GrokUsageAPI.parseAuthFile(Data(json.utf8)) == nil)
    }

    // MARK: - Endpoint URL

    @Test
    func defaultBaseUsesCreditsQuery() {
        let url = GrokUsageAPI.billingURL(base: GrokUsageAPI.defaultBaseURL)
        #expect(url.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
    }

    @Test
    func trimsTrailingSlashOnCustomProxy() {
        let url = GrokUsageAPI.billingURL(base: "https://proxy.example.com/v1/")
        #expect(url.absoluteString == "https://proxy.example.com/v1/billing?format=credits")
    }

    @Test
    func readsCliChatProxyBaseURLFromEndpointsTable() {
        let toml = """
        model = "grok-4"

        [endpoints]
        cli_chat_proxy_base_url = "https://proxy.example.com/v1"

        [features]
        telemetry = false
        """
        #expect(GrokUsageAPI.parseCliChatProxyBaseURL(toml) == "https://proxy.example.com/v1")
    }

    @Test
    func ignoresCliChatProxyBaseURLOutsideEndpointsTable() {
        let toml = """
        cli_chat_proxy_base_url = "https://leaked.example.com"

        [features]
        cli_chat_proxy_base_url = "https://also-leaked.example.com"
        """
        #expect(GrokUsageAPI.parseCliChatProxyBaseURL(toml) == nil)
    }

    // MARK: - Snapshot cache

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-tests-\(UUID().uuidString)")
            .appendingPathComponent("grok-rate-limits.json")
    }

    private var testScope: String {
        GrokUsageAPI.cacheScope(
            accountID: "user-a",
            billingURL: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        )!
    }

    @Test
    func cacheRoundTripPreservesLiveFields() throws {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fetchedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let live = ProviderRateLimit(
            provider: .grok,
            sevenDay: RateLimitWindow(
                utilization: 9,
                resetsAt: fetchedAt.addingTimeInterval(3 * 86_400),
                windowDuration: 604_800
            ),
            planLabel: "SuperGrok Plus",
            status: .ok,
            fetchedAt: fetchedAt,
            dataAsOf: fetchedAt
        )
        GrokUsageAPI.cache(live, scope: testScope, to: url)

        let persisted = try String(contentsOf: url, encoding: .utf8)
        #expect(!persisted.contains("user-a"))
        #expect(!persisted.contains("cli-chat-proxy.grok.com"))

        let now = fetchedAt.addingTimeInterval(600)
        let cached = try #require(GrokUsageAPI.cachedSnapshot(from: url, now: now, scope: testScope))
        #expect(cached.sevenDay?.utilization == 9)
        #expect(cached.planLabel == "SuperGrok Plus")
        #expect(cached.dataAsOf == fetchedAt)
        #expect(cached.fetchedAt == now)
    }

    @Test
    func cachedSnapshotNilWhenWindowExpired() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fetchedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let live = ProviderRateLimit(
            provider: .grok,
            sevenDay: RateLimitWindow(
                utilization: 9,
                resetsAt: fetchedAt.addingTimeInterval(86_400),
                windowDuration: 604_800
            ),
            status: .ok,
            fetchedAt: fetchedAt,
            dataAsOf: fetchedAt
        )
        GrokUsageAPI.cache(live, scope: testScope, to: url)

        let now = fetchedAt.addingTimeInterval(2 * 86_400)
        #expect(GrokUsageAPI.cachedSnapshot(from: url, now: now, scope: testScope) == nil)
    }

    @Test
    func noDataLiveSnapshotClearsMatchingCache() throws {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fetchedAt = Date(timeIntervalSince1970: 1_788_000_000)
        GrokUsageAPI.cache(
            ProviderRateLimit(
                provider: .grok,
                sevenDay: RateLimitWindow(
                    utilization: 9,
                    resetsAt: fetchedAt.addingTimeInterval(86_400),
                    windowDuration: 604_800
                ),
                status: .ok,
                fetchedAt: fetchedAt,
                dataAsOf: fetchedAt
            ),
            scope: testScope,
            to: url
        )
        #expect(FileManager.default.fileExists(atPath: url.path))

        GrokUsageAPI.cache(
            ProviderRateLimit(provider: .grok, status: .noData, fetchedAt: fetchedAt),
            scope: testScope,
            to: url
        )
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func cacheScopeRequiresAccountIdentity() {
        let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        #expect(GrokUsageAPI.cacheScope(accountID: nil, billingURL: url) == nil)
        #expect(GrokUsageAPI.cacheScope(accountID: "", billingURL: url) == nil)
    }

    @Test
    func parseISO8601AcceptsGrokFractionalOffset() throws {
        let date = try #require(GrokUsageAPI.parseISO8601("2026-08-27T06:44:52.255770+00:00"))
        #expect(date.timeIntervalSince1970 > 1_700_000_000)
    }
}
