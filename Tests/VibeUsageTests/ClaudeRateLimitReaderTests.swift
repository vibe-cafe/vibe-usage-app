import Foundation
import Testing
@testable import VibeUsage

struct ClaudeRateLimitReaderTests {
    @Test
    func mapsMaxTiersToDistinctBadges() {
        #expect(ClaudeRateLimitReader.formatTier("default_claude_max_20x") == "Max 20x")
        #expect(ClaudeRateLimitReader.formatTier("default_claude_max_5x") == "Max 5x")
        // A bare "max" with no multiplier still resolves to the base badge.
        #expect(ClaudeRateLimitReader.formatTier("default_claude_max") == "Max")
    }

    @Test
    func mapsNonMaxTiers() {
        #expect(ClaudeRateLimitReader.formatTier("default_claude_pro") == "Pro")
        #expect(ClaudeRateLimitReader.formatTier("claude_team") == "Team")
        #expect(ClaudeRateLimitReader.formatTier("free") == "Free")
    }

    @Test
    func suppressesApiAndEmptyTiers() {
        // API-key users carry no meaningful subscription badge.
        #expect(ClaudeRateLimitReader.formatTier("api") == nil)
        #expect(ClaudeRateLimitReader.formatTier("") == nil)
        #expect(ClaudeRateLimitReader.formatTier(nil) == nil)
    }

    @Test
    func titleCasesUnknownTiers() {
        // A future/unrecognized tier still surfaces something readable rather
        // than silently vanishing.
        #expect(ClaudeRateLimitReader.formatTier("default_claude_ultra") == "Ultra")
    }
}
