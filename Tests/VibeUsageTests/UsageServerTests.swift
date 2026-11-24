import Foundation
import Testing
@testable import VibeUsage

struct UsageServerTests {
    @Test func onlyLegacyProductionBasesMigrate() {
        for legacy in ["https://vibecafe.ai", "HTTPS://WWW.VIBECAFE.AI///"] {
            #expect(UsageServer(legacy).baseURL == "https://vibefriends.com")
        }
        for custom in [
            "http://localhost:3000", "https://SELF.example/Prefix/", "http://vibecafe.ai",
            "https://vibecafe.ai:443", "https://vibecafe.ai/prefix", "https://vibecafe.ai.example",
            "https://vibecafe.ai?server=other", "https://vibecafe.ai#custom",
            "https://vibefriends.com/",
        ] {
            #expect(UsageServer(custom).baseURL == custom)
        }
        #if DEBUG
        let fallback = "http://localhost:3000"
        #else
        let fallback = "https://vibefriends.com"
        #endif
        #expect(UsageServer(nil).baseURL == fallback)
        #expect(UsageServer("").baseURL == fallback)
    }

    @Test func routesKeepTheConfiguredServerAndPathPrefix() {
        let server = UsageServer("https://self.example/Tenant/")
        #expect(server.siteURL?.absoluteString == "https://self.example/Tenant/")
        for path in ["usage", "rank", "api/usage", "api/usage/device/code", "api/usage/device/poll"] {
            #expect(server.url(for: path)?.absoluteString == "https://self.example/Tenant/" + path)
        }
    }

    @Test func approvalKeepsItsEncodedCodeAndCustomOrigins() {
        let suffix = "/approve/%2F?user_code=A%2BB&next=%2Fr#ok"
        let legacy = "HTTPS://WWW.VibeCafe.AI" + suffix
        let production = UsageServer("HTTPS://VIBEFRIENDS.COM/")
        #expect(production.verificationURL(legacy)?.absoluteString == "https://vibefriends.com" + suffix)
        let custom = UsageServer("https://vibecafe.ai/Tenant")
        #expect(custom.verificationURL(legacy)?.absoluteString == legacy)
        for base in ["http://localhost:3000", "https://identity.example", "https://vibecafe.ai.example",
                     "https://vibecafe.ai:443", "https://vibecafe.ai@other.example"] {
            #expect(production.verificationURL(base + suffix)?.absoluteString == base + suffix)
        }
    }

    @Test func bindingSavesTheMappedReplyOrTheServerThatIssuedTheCode() {
        let requested = UsageServer("http://localhost:4567/tenant/")
        for (reply, expected) in [
            ("https://VibeCafe.ai/", "https://vibefriends.com"),
            ("https://own.example/Base/", "https://own.example/Base/"),
            (nil, requested.baseURL), ("", requested.baseURL),
        ] {
            let result = DevicePollResponse(apiKey: "fixture", apiUrl: reply, error: nil)
            #expect(result.linkedServer(fallingBackTo: requested).baseURL == expected)
        }
    }
}
