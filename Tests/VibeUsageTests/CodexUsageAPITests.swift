import Foundation
import Testing
@testable import VibeUsage

struct CodexUsageAPITests {

    // MARK: - Response parsing

    /// The live shape since OpenAI dropped the 5h window (2026-07-12): the
    /// weekly window sits in `primary_window` and `secondary_window` is null.
    /// Position must not matter — classification is by window length.
    @Test
    func parsesWeeklyOnlyResponseAndFlagsFiveHourNotEnforced() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 89,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 510083,
              "reset_at": 1784680014
            },
            "secondary_window": null
          },
          "rate_limit_reset_credits": { "available_count": 3 }
        }
        """
        let snapshot = try #require(CodexUsageAPI.parseUsageResponse(Data(json.utf8), now: now))

        #expect(snapshot.status == .ok)
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.fiveHourNotEnforced)
        #expect(snapshot.sevenDay?.utilization == 89)
        #expect(snapshot.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_784_680_014))
        #expect(snapshot.sevenDay?.windowDuration == 604_800)
        #expect(snapshot.planLabel == "Plus")
        #expect(snapshot.resetCreditsCount == 3)
        #expect(snapshot.dataAsOf == now)
    }

    /// Historic dual-window shape, deliberately swapped (5h in secondary) to
    /// pin the classify-by-length behavior.
    @Test
    func classifiesWindowsByLengthNotSlotPosition() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 37,
              "limit_window_seconds": 604800,
              "reset_at": 1784680014
            },
            "secondary_window": {
              "used_percent": 12,
              "limit_window_seconds": 18000,
              "reset_at": 1784100000
            }
          }
        }
        """
        let snapshot = try #require(CodexUsageAPI.parseUsageResponse(Data(json.utf8)))

        #expect(snapshot.fiveHour?.utilization == 12)
        #expect(snapshot.fiveHour?.windowDuration == 18_000)
        #expect(!snapshot.fiveHourNotEnforced)
        #expect(snapshot.sevenDay?.utilization == 37)
        #expect(snapshot.resetCreditsCount == nil)
    }

    /// `reset_after_seconds` is the fallback when `reset_at` is absent.
    @Test
    func derivesResetFromResetAfterSecondsWhenResetAtMissing() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 50,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 3600
            }
          }
        }
        """
        let snapshot = try #require(CodexUsageAPI.parseUsageResponse(Data(json.utf8), now: now))

        #expect(snapshot.fiveHour?.resetsAt == now.addingTimeInterval(3600))
    }

    /// Both windows null (no enforced limits at all) → `.noData`, so the card
    /// collapses instead of rendering an empty shell.
    @Test
    func reportsNoDataWhenNoWindowIsEnforced() throws {
        let json = """
        { "plan_type": "free", "rate_limit": { "primary_window": null, "secondary_window": null } }
        """
        let snapshot = try #require(CodexUsageAPI.parseUsageResponse(Data(json.utf8)))
        #expect(snapshot.status == .noData)
    }

    @Test
    func rejectsResponsesWithoutRateLimitObject() {
        let json = #"{ "detail": "Something went wrong" }"#
        #expect(CodexUsageAPI.parseUsageResponse(Data(json.utf8)) == nil)
    }

    // MARK: - auth.json parsing

    @Test
    func parsesTokensFromAuthFile() throws {
        let json = """
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "id_token": "eyJ...",
            "access_token": "at-123",
            "refresh_token": "rt-456",
            "account_id": "acc-789"
          },
          "last_refresh": "2026-07-15T00:00:00Z"
        }
        """
        let auth = try #require(CodexUsageAPI.parseAuthFile(Data(json.utf8)))
        #expect(auth.accessToken == "at-123")
        #expect(auth.accountID == "acc-789")
    }

    /// API-key-only logins have no `tokens` object — the usage endpoint only
    /// works for subscription (OAuth) auth, so this must read as "not logged in".
    @Test
    func rejectsAuthFileWithoutOAuthTokens() {
        let json = #"{ "OPENAI_API_KEY": "sk-abc" }"#
        #expect(CodexUsageAPI.parseAuthFile(Data(json.utf8)) == nil)
    }

    // MARK: - Endpoint URL resolution

    @Test
    func defaultBaseUsesWhamPath() {
        let url = CodexUsageAPI.usageURL(base: "https://chatgpt.com/backend-api")
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    }

    /// ChatGPT-style hosts get `/backend-api` appended when missing, matching
    /// the CLI's own normalization of `chatgpt_base_url`.
    @Test
    func appendsBackendAPIToBareChatGPTHost() {
        let url = CodexUsageAPI.usageURL(base: "https://chatgpt.com/")
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    }

    /// Non-ChatGPT proxies without a backend-api segment route via the public
    /// API path instead.
    @Test
    func usesPublicAPIPathForNonBackendAPIProxy() {
        let url = CodexUsageAPI.usageURL(base: "https://proxy.example.com")
        #expect(url.absoluteString == "https://proxy.example.com/api/codex/usage")
    }

    // MARK: - config.toml scanning

    @Test
    func readsTopLevelChatGPTBaseURL() {
        let toml = """
        model = "gpt-5.4"
        chatgpt_base_url = "https://proxy.example.com/backend-api"

        [profiles.work]
        model = "gpt-5.4-mini"
        """
        #expect(CodexUsageAPI.parseChatGPTBaseURL(toml) == "https://proxy.example.com/backend-api")
    }

    /// A same-named key inside a table must not leak out as the top-level value.
    @Test
    func ignoresChatGPTBaseURLInsideTables() {
        let toml = """
        model = "gpt-5.4"

        [profiles.work]
        chatgpt_base_url = "https://work-proxy.example.com"
        """
        #expect(CodexUsageAPI.parseChatGPTBaseURL(toml) == nil)
    }

    // MARK: - Snapshot cache

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-tests-\(UUID().uuidString)")
            .appendingPathComponent("codex-rate-limits.json")
    }

    @Test
    func cacheRoundTripPreservesLiveFields() throws {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fetchedAt = Date(timeIntervalSince1970: 1_784_000_000)
        let live = ProviderRateLimit(
            provider: .codex,
            sevenDay: RateLimitWindow(
                utilization: 42,
                resetsAt: fetchedAt.addingTimeInterval(3 * 86_400),
                windowDuration: 604_800
            ),
            planLabel: "Plus",
            status: .ok,
            fetchedAt: fetchedAt,
            dataAsOf: fetchedAt,
            fiveHourNotEnforced: true,
            resetCreditsCount: 3
        )
        CodexUsageAPI.cache(live, to: url)

        let now = fetchedAt.addingTimeInterval(600)
        let cached = try #require(CodexUsageAPI.cachedSnapshot(from: url, now: now))

        #expect(cached.status == .ok)
        #expect(cached.sevenDay?.utilization == 42)
        #expect(cached.sevenDay?.windowDuration == 604_800)
        #expect(cached.planLabel == "Plus")
        #expect(cached.fiveHourNotEnforced)
        #expect(cached.resetCreditsCount == 3)
        // dataAsOf must survive as the ORIGINAL fetch time (drives the
        // 「数据截至」 note), while fetchedAt reflects the read.
        #expect(cached.dataAsOf == fetchedAt)
        #expect(cached.fetchedAt == now)
    }

    /// A cached window whose reset has passed is provably rolled over — its
    /// percentage belongs to the previous window and must not be painted.
    /// The surviving window keeps the card useful.
    @Test
    func cachedSnapshotDropsExpiredWindowsIndependently() throws {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fetchedAt = Date(timeIntervalSince1970: 1_784_000_000)
        let live = ProviderRateLimit(
            provider: .codex,
            fiveHour: RateLimitWindow(
                utilization: 80,
                resetsAt: fetchedAt.addingTimeInterval(3600),
                windowDuration: 18_000
            ),
            sevenDay: RateLimitWindow(
                utilization: 42,
                resetsAt: fetchedAt.addingTimeInterval(3 * 86_400),
                windowDuration: 604_800
            ),
            status: .ok,
            fetchedAt: fetchedAt,
            dataAsOf: fetchedAt
        )
        CodexUsageAPI.cache(live, to: url)

        // Two hours later the 5h window has reset; the weekly one hasn't.
        let now = fetchedAt.addingTimeInterval(2 * 3600)
        let cached = try #require(CodexUsageAPI.cachedSnapshot(from: url, now: now))

        #expect(cached.fiveHour == nil)
        // An expiry-dropped 5h window says nothing about enforcement.
        #expect(!cached.fiveHourNotEnforced)
        #expect(cached.sevenDay?.utilization == 42)
    }

    /// All windows expired → nil, so the paint step shows nothing rather than
    /// confidently-wrong percentages. Weekly resets within 7 days, so this is
    /// also the natural age cap for the whole cache.
    @Test
    func cachedSnapshotNilWhenEveryWindowExpired() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fetchedAt = Date(timeIntervalSince1970: 1_784_000_000)
        let live = ProviderRateLimit(
            provider: .codex,
            sevenDay: RateLimitWindow(
                utilization: 42,
                resetsAt: fetchedAt.addingTimeInterval(86_400),
                windowDuration: 604_800
            ),
            status: .ok,
            fetchedAt: fetchedAt,
            dataAsOf: fetchedAt
        )
        CodexUsageAPI.cache(live, to: url)

        let now = fetchedAt.addingTimeInterval(8 * 86_400)
        #expect(CodexUsageAPI.cachedSnapshot(from: url, now: now) == nil)
    }

    @Test
    func cachedSnapshotNilWhenFileMissing() {
        #expect(CodexUsageAPI.cachedSnapshot(from: tempCacheURL()) == nil)
    }
}
