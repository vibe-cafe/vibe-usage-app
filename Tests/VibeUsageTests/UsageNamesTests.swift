import Foundation
import Testing
@testable import VibeUsage

/// The app renders the names the server sent and keeps **no** naming table of
/// its own. These cases pin that contract: the names arrive on the usage
/// response, a lookup the server could not answer falls back to the raw id
/// (exactly what the app showed before the field existed), a merged display
/// name selects every raw id behind it, and the model filter's families are the
/// server's rows rather than a table the app maintains.
struct UsageNamesTests {
    private static let namesPayload = """
    "names": {
      "sources": {"kimi-code": "Kimi Code", "opencode": "OpenCode"},
      "models": {"k3": "Kimi K3", "kimi-code/k3-256k": "Kimi K3"},
      "modelFamilies": {"k3": "kimi", "kimi-code/k3-256k": "kimi"},
      "families": [{"key": "kimi", "label": "Kimi", "provider": "Moonshot AI"}]
    }
    """

    /// Two raw ids that the server merges into one name, from two sources.
    private func response(names: String) throws -> UsageResponse {
        let json = """
        {
          "hasAnyData": true,
          "buckets": [
            {"source": "kimi-code", "model": "k3", "project": "p", "hostname": "h",
             "bucketStart": "2026-10-01T10:00:00.000Z",
             "inputTokens": 10, "outputTokens": 1, "cachedInputTokens": 0,
             "reasoningOutputTokens": 0, "totalTokens": 11},
            {"source": "opencode", "model": "kimi-code/k3-256k", "project": "p", "hostname": "h",
             "bucketStart": "2026-10-01T10:30:00.000Z",
             "inputTokens": 20, "outputTokens": 2, "cachedInputTokens": 0,
             "reasoningOutputTokens": 0, "totalTokens": 22}
          ],
          \(names)
        }
        """
        return try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    @MainActor
    private func loadedState(names: String) async throws -> AppState {
        let response = try response(names: names)
        let state = AppState(
            initialConfig: VibeUsageConfig(apiKey: "test-key", apiUrl: "https://example.test"),
            usageFetcher: { _, _, _ in response }
        )
        await state.fetchUsageData()
        return state
    }

    @Test @MainActor
    func theServerNamesReachTheApp() async throws {
        let state = try await loadedState(names: Self.namesPayload)
        #expect(state.buckets.count == 2)
        #expect(state.toolName("kimi-code") == "Kimi Code")
        #expect(state.modelName("k3") == "Kimi K3")
        #expect(state.modelName("kimi-code/k3-256k") == "Kimi K3")
        // An id the server did not name stays exactly as reported.
        #expect(state.modelName("acme-coder-2.5") == "acme-coder-2.5")
        #expect(state.toolName("some-new-cli") == "some-new-cli")
    }

    /// A server that predates the field must not break the app: no names, raw
    /// ids on screen, which is what every build before this one showed. The
    /// model filter then has nothing to group by, so every id lands in 其他 —
    /// the filter still works, it just cannot group.
    @Test @MainActor
    func aResponseWithoutNamesDecodesAndShowsRawIds() async throws {
        let state = try await loadedState(names: "\"names\": null")
        #expect(state.buckets.count == 2)
        #expect(state.toolName("kimi-code") == "kimi-code")
        #expect(state.modelName("k3") == "k3")
        #expect(state.modelFilterGroups.map(\.key) == ["other"])
        #expect(state.modelFilterGroups.first?.models == ["k3", "kimi-code/k3-256k"])
    }

    /// One name merges several reported ids, so selecting it must select all of
    /// them — the reason the filter stores display names rather than id lists.
    @Test @MainActor
    func selectingAMergedNameMatchesEveryRawIdBehindIt() async throws {
        let state = try await loadedState(names: Self.namesPayload)
        state.filters.models = ["Kimi K3"]
        #expect(state.buckets.allSatisfy { state.matchesFilters($0) })
        state.filters.models = ["Kimi K2"]
        #expect(state.buckets.allSatisfy { !state.matchesFilters($0) })
    }

    /// The model filter groups by the server's family rows, in the server's
    /// order, with one option per display name and anything unplaced in 其他.
    @Test @MainActor
    func modelFilterGroupsFollowTheServerFamilies() async throws {
        let state = try await loadedState(names: Self.namesPayload)
        let groups = state.modelFilterGroups
        #expect(groups.map(\.key) == ["kimi"])
        #expect(groups.first?.label == "Kimi")
        #expect(groups.first?.models == ["Kimi K3"])
    }

    @Test @MainActor
    func unplacedNamesFallIntoOther() async throws {
        let state = try await loadedState(names: """
        "names": {
          "sources": {},
          "models": {"k3": "Kimi K3"},
          "modelFamilies": {"k3": "kimi"},
          "families": [{"key": "kimi", "label": "Kimi", "provider": "Moonshot AI"}]
        }
        """)
        let groups = state.modelFilterGroups
        // "kimi-code/k3-256k" was named but not placed by the server.
        #expect(groups.map(\.key) == ["kimi", "other"])
        #expect(groups.last?.label == "其他")
        #expect(groups.last?.models == ["kimi-code/k3-256k"])
    }
}
