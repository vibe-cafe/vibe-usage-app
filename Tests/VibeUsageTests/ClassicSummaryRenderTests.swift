import SwiftUI
import Testing
@testable import VibeUsage

/// Opt-in maintainer preview of the actual 520 pt panel row in its normal insets.
struct ClassicSummaryRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBE_USAGE_RENDER_CLASSIC_SUMMARY"] == "1"))
    @MainActor func renderFixedSummaryCards() async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sample = UsageBucket(source: "demo", model: "demo", project: "demo", hostname: "demo",
                                 bucketStart: "2026-11-25T06:00:00Z", inputTokens: 2_000_000,
                                 outputTokens: 400_000, cacheCreationInputTokens: nil, cachedInputTokens: 8_000_000,
                                 reasoningOutputTokens: 0, totalTokens: 10_400_000, estimatedCost: 12.34)
        for available in [true, false] {
            let state = AppState(
                loadConfig: { VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test") },
                usageFetcher: { _, _, _ in
                    UsageResponse(buckets: [sample], sessions: nil, hasAnyData: true, names: nil)
                },
                activityFetcher: { _, _, _, _ in
                    guard available else { throw URLError(.timedOut) }
                    return UsageActivity(activeSeconds: 8_400, workSeconds: 21_000, parallel: 2.5,
                                         series: [], firstBucketStart: "2026-11-20T00:00:00Z")
                }
            )
            await state.fetchUsageData()
            if available { try await waitForDashboard { state.activity != nil } }
            let view = SummaryCardsView()
                .environment(state)
                .environment(\.colorScheme, .dark)
                .padding(16)
                .frame(width: 520)
                .background(Color(white: 0.04))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == 1040)
            #expect(image.height == 204)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            let name = available ? "classic-summary.png" : "classic-summary-unavailable.png"
            try png.write(to: directory.appendingPathComponent(name))
        }
    }
}
