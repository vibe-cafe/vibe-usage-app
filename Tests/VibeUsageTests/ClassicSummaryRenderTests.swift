import SwiftUI
import Testing
@testable import VibeUsage

/// Opt-in maintainer previews of the classic panel at its normal width and insets.
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
        var shouldFail = false
        let state = AppState(
            loadConfig: { VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test") },
            usageFetcher: { _, _, _ in
                UsageResponse(buckets: [sample], sessions: nil, hasAnyData: true, names: nil)
            },
            activityFetcher: { _, _, _, _ in
                guard !shouldFail else { throw URLError(.timedOut) }
                return UsageActivity(activeSeconds: 8_400, workSeconds: 21_000, parallel: 2.5, series: [
                    .init(periodStart: "2026-11-23T00:00:00Z", activeSeconds: 1_800, workSeconds: 3_000),
                    .init(periodStart: "2026-11-24T00:00:00Z", activeSeconds: 3_600, workSeconds: 9_000),
                    .init(periodStart: "2026-11-25T00:00:00Z", activeSeconds: 3_000, workSeconds: 9_000),
                ], firstBucketStart: "2026-11-20T00:00:00Z")
            }
        )
        state.timeRange = .custom
        state.customRangeFrom = try #require(Formatters.dateFromDayKey("2026-11-21"))
        state.customRangeTo = try #require(Formatters.dateFromDayKey("2026-11-27"))
        state.chartMode = .activeTime

        func render(_ content: some View, name: String, height: Int? = nil) throws {
            let view = content
                .environment(state)
                .environment(\.colorScheme, .dark)
                .padding(16)
                .frame(width: 520)
                .background(Color(white: 0.04))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == 1040)
            if let height { #expect(image.height == height) }
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(name))
        }

        await state.fetchUsageData()
        try await waitForDashboard { state.activity != nil }
        try render(SummaryCardsView(), name: "classic-summary.png", height: 204)
        // ImageRenderer has no pointer. Select Nov 24 in the same overlay a hover would display.
        try render(BarChartView(initialHoveredIndex: 3), name: "classic-active-trend-hover.png")

        shouldFail = true
        await state.fetchUsageData()
        try await waitForDashboard { state.activity == nil }
        try render(SummaryCardsView(), name: "classic-summary-unavailable.png", height: 204)
    }
}
