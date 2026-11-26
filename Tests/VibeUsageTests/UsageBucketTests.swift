import Foundation
import Testing
@testable import VibeUsage

struct UsageBucketTests {
    // The same usage before and after cache writes were split out of input.
    private let responseJSON = """
    {
      "hasAnyData": true,
      "buckets": [
        {"source": "claude-code", "model": "test", "project": "p", "hostname": "h",
         "bucketStart": "2026-09-16T00:00:00Z", "inputTokens": 100,
         "cacheCreation5mTokens": 7, "cacheCreation1hTokens": 13,
         "outputTokens": 20, "reasoningOutputTokens": 5, "cachedInputTokens": 40, "totalTokens": 125},
        {"source": "claude-code", "model": "test", "project": "p", "hostname": "h",
         "bucketStart": "2026-09-15T00:00:00Z", "inputTokens": 120,
         "outputTokens": 20, "reasoningOutputTokens": 5, "cachedInputTokens": 40, "totalTokens": 145}
      ]
    }
    """

    @Test @MainActor
    func panelAndMenuBarCountCacheWritesOnceAcrossBothBucketFormats() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(responseJSON.utf8))
        #expect(response.buckets.map(\.computedTotal) == [185, 185])

        let state = AppState(loadConfig: { nil })
        state.timeRange = .sevenDays
        state.buckets = response.buckets
        #expect(state.menuBarTokens == 370)
    }

    @Test
    func trendCountsCacheWritesAsInputAndOnlyReadsAsCached() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(responseJSON.utf8))
        for bucket in response.buckets {
            var bar = BarData(id: bucket.dayKey)
            bar.add(bucket)
            #expect(bar.input == 120)
            #expect(bar.output == 25)
            #expect(bar.cached == 40)
            #expect(bar.total == bucket.computedTotal)
        }
    }
}
