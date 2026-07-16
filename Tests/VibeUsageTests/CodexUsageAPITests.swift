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
}
