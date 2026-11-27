import Foundation
import Testing
@testable import VibeUsage

private actor UsageFetchStub {
    private struct PendingRequest {
        let continuation: CheckedContinuation<UsageResponse, any Error>
    }

    private var requests: [PendingRequest] = []

    func fetch(_ range: UsageQueryRange) async throws -> UsageResponse {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(PendingRequest(continuation: continuation))
        }
    }

    func waitForRequestCount(_ count: Int) async {
        while requests.count < count {
            await Task.yield()
        }
    }

    var requestCount: Int {
        requests.count
    }

    func resolveRequest(at index: Int, with response: UsageResponse) {
        requests[index].continuation.resume(returning: response)
    }
}

struct AppStateUsageFetchTests {
    @Test @MainActor
    func slowActivityDoesNotDelayUsageRefreshOrRestoreAnUnlinkedAccount() async throws {
        var pending: CheckedContinuation<UsageActivity, Never>?
        var finished = false
        let state = AppState(
            initialConfig: VibeUsageConfig(apiKey: "fixture", apiUrl: "https://example.test"),
            loadConfig: { nil },
            usageFetcher: { _, _, _ in UsageResponse(buckets: [], sessions: nil, hasAnyData: true, names: nil) },
            activityFetcher: { _, _, _, _, _ in await withCheckedContinuation { pending = $0 } }
        )
        let refresh = Task {
            await state.fetchUsageData()
            finished = true
        }
        try await waitForDashboard { pending != nil && state.hasLoadedUsageData }
        #expect(finished)
        state.applyConfig(nil)
        pending?.resume(returning: UsageActivity(activeSeconds: 60, workSeconds: 60, parallel: 1,
                                                 series: [], firstBucketStart: "2026-01-01T00:00:00Z"))
        await refresh.value
        await Task.yield()
        #expect(state.activity == nil)
    }

    @Test @MainActor
    func activityFailureLeavesCostAndTokensVisibleAndOnlySupportedFiltersRefetch() async throws {
        let sample = bucket(source: "fixture")
        let activity = UsageActivity(activeSeconds: 60, workSeconds: 120, parallel: 2,
                                     series: [], firstBucketStart: "2026-01-01T00:00:00Z")
        var requests: [FilterState] = []
        var usageReads = 0
        let state = AppState(
            initialConfig: VibeUsageConfig(apiKey: "test-key", apiUrl: "https://example.test"),
            loadConfig: { nil },
            usageFetcher: { _, _, _ in
                usageReads += 1
                return UsageResponse(buckets: [sample], sessions: nil, hasAnyData: true, names: nil)
            },
            activityFetcher: { _, _, _, filters, _ in
                requests.append(filters)
                if requests.count == 2 || requests.count == 4 { throw URLError(.timedOut) }
                return activity
            }
        )
        await state.fetchUsageData()
        try await waitForDashboard { state.activity != nil }
        #expect(state.activity?.summary?.activeText == "1m")
        state.filters.models = ["test-model"]
        await Task.yield()
        #expect(requests.count == 1)
        state.filters.projects = ["test-project"]
        try await waitForDashboard { requests.count == 2 }
        #expect(state.activity == nil)
        #expect(state.matchesFilters(sample))
        #expect(state.buckets.first?.computedTotal == 10)
        #expect(state.buckets.first?.estimatedCost == 0.01)

        #expect(requests.last?.projects == ["test-project"])
        #expect(usageReads == 1)
        await state.fetchUsageData()
        try await waitForDashboard { state.activity != nil }
        #expect(requests.count == 3)
        // A failed refresh of the same query must also replace an existing success.
        await state.fetchUsageData()
        try await waitForDashboard { state.activity == nil }
        #expect(requests.count == 4)
    }

    @Test @MainActor
    func refreshReadsDiskAndRetainsTheLastReadableConfig() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var servers: [String] = []
        var keys: [String] = []
        let state = AppState(
            loadConfig: { ConfigManager.load(from: file) },
            usageFetcher: { server, key, _ in
                servers.append(server.baseURL)
                keys.append(key)
                return UsageResponse(buckets: [], sessions: nil, hasAnyData: false, names: nil)
            },
            activityFetcher: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) }
        )

        let old = Data(#"{"apiKey":"one","apiUrl":"https://WWW.VibeCafe.ai///","cliField":1}"#.utf8)
        try old.write(to: file)
        await state.fetchUsageData()
        #expect(try Data(contentsOf: file) == old)

        let production = "https://vibefriends.com"
        let migrated = VibeUsageConfig(apiKey: "one", apiUrl: production)
        try JSONEncoder().encode(migrated).write(to: file, options: .atomic)
        await state.fetchUsageData()

        let custom = "http://localhost:4321/Dev/"
        let replacement = VibeUsageConfig(apiKey: "two", apiUrl: custom)
        try JSONEncoder().encode(replacement).write(to: file, options: .atomic)
        await state.fetchUsageData()
        #expect(state.usageServer.siteURL?.absoluteString == custom)

        try Data("{".utf8).write(to: file)
        await state.fetchUsageData()
        try FileManager.default.removeItem(at: file)
        await state.fetchUsageData()
        #expect(servers == [production, production, custom, custom, custom])
        #expect(keys == ["one", "one", "two", "two", "two"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test @MainActor
    func passivePopoverRefreshDoesNotDuplicateInflightLaunchFetch() async {
        let stub = UsageFetchStub()
        let state = AppState(
            initialConfig: VibeUsageConfig(apiKey: "test-key", apiUrl: "https://example.test"),
            loadConfig: { nil },
            usageFetcher: { _, _, range in
                try await stub.fetch(range)
            },
            activityFetcher: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) }
        )

        let launchRequest = Task { @MainActor in
            await state.fetchUsageData()
        }
        await stub.waitForRequestCount(1)

        await state.fetchUsageDataIfNeeded()
        #expect(await stub.requestCount == 1)

        await stub.resolveRequest(
            at: 0,
            with: UsageResponse(buckets: [], sessions: nil, hasAnyData: false, names: nil)
        )
        await launchRequest.value
    }

    @Test @MainActor
    func olderResponseCannotOverwriteNewerRange() async {
        let stub = UsageFetchStub()
        let state = AppState(
            initialConfig: VibeUsageConfig(apiKey: "test-key", apiUrl: "https://example.test"),
            loadConfig: { nil },
            usageFetcher: { _, _, range in
                try await stub.fetch(range)
            },
            activityFetcher: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) }
        )

        let olderRequest = Task { @MainActor in
            await state.fetchUsageData()
        }
        await stub.waitForRequestCount(1)

        state.timeRange = .sevenDays
        let newerRequest = Task { @MainActor in
            await state.fetchUsageData()
        }
        await stub.waitForRequestCount(2)

        let newestBucket = bucket(source: "newest")
        await stub.resolveRequest(
            at: 1,
            with: UsageResponse(buckets: [newestBucket], sessions: nil, hasAnyData: true, names: nil)
        )
        await newerRequest.value

        #expect(state.buckets == [newestBucket])
        #expect(!state.isLoadingData)

        let staleBucket = bucket(source: "stale")
        await stub.resolveRequest(
            at: 0,
            with: UsageResponse(buckets: [staleBucket], sessions: nil, hasAnyData: true, names: nil)
        )
        await olderRequest.value

        #expect(state.buckets == [newestBucket])
        #expect(!state.isLoadingData)
    }

    @Test @MainActor
    func staleCompletionDoesNotEndLatestLoadingState() async {
        let stub = UsageFetchStub()
        let state = AppState(
            initialConfig: VibeUsageConfig(apiKey: "test-key", apiUrl: "https://example.test"),
            loadConfig: { nil },
            usageFetcher: { _, _, range in
                try await stub.fetch(range)
            },
            activityFetcher: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) }
        )

        let olderRequest = Task { @MainActor in
            await state.fetchUsageData()
        }
        await stub.waitForRequestCount(1)

        state.timeRange = .thirtyDays
        let newerRequest = Task { @MainActor in
            await state.fetchUsageData()
        }
        await stub.waitForRequestCount(2)

        await stub.resolveRequest(
            at: 0,
            with: UsageResponse(buckets: [bucket(source: "stale")], sessions: nil, hasAnyData: true, names: nil)
        )
        await olderRequest.value

        #expect(state.buckets.isEmpty)
        #expect(state.isLoadingData)

        let newestBucket = bucket(source: "newest")
        await stub.resolveRequest(
            at: 1,
            with: UsageResponse(buckets: [newestBucket], sessions: nil, hasAnyData: true, names: nil)
        )
        await newerRequest.value

        #expect(state.buckets == [newestBucket])
        #expect(!state.isLoadingData)
    }

    private func bucket(source: String) -> UsageBucket {
        UsageBucket(
            source: source,
            model: "test-model",
            project: "test-project",
            hostname: "test-host",
            bucketStart: "2026-07-22T00:00:00Z",
            inputTokens: 1,
            outputTokens: 2,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            cachedInputTokens: 3,
            reasoningOutputTokens: 4,
            totalTokens: 10,
            estimatedCost: 0.01
        )
    }
}
