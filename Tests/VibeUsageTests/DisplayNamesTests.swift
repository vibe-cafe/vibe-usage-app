import Testing
@testable import VibeUsage

struct DisplayNamesTests {
    @Test(arguments: [
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
        ("gemini-3.8-flash", "Gemini 3.8 Flash"),
        ("gpt-5.6-sol", "GPT-5.6 Sol"),
        ("GLM-5.3", "GLM-5.3"),
        ("deepseek-v4-pro", "DeepSeek V4 Pro"),
    ])
    func catalogSuppliesOfficialCasing(raw: String, expected: String) {
        #expect(DisplayNames.model(raw) == expected)
    }

    @Test(arguments: [
        "gemini-3.8-flash", "gemini-3.8-flash-high", "gemini-3.8-flash-medium",
        "gemini-3.8-flash-n", "gemini-3.8-flash-exp-b",
    ])
    func effortAndServingTagsShareOneName(raw: String) {
        #expect(DisplayNames.model(raw) == "Gemini 3.8 Flash")
    }

    @Test(arguments: [
        "k3", "k3-256k", "kimi-k3-256k", "kimi-code/k3", "kimi-code/k3-256k",
    ])
    func routerPrefixesContextSizesAndShortIdsMerge(raw: String) {
        #expect(DisplayNames.model(raw) == "Kimi K3")
    }

    @Test
    func variantsStripOnlyWhenTheBaseIsAKnownModel() {
        // "max" is part of these models' names, not an effort level.
        #expect(DisplayNames.model("qwen3-max") == "Qwen3 Max")
        #expect(DisplayNames.model("gpt-5.1-codex-max") == "GPT-5.1 Codex Max")
        #expect(DisplayNames.model("claude-opus-4-6-thinking") == "Claude Opus 4.6")
        #expect(DisplayNames.model("swe-2-max") == "SWE-2")
        #expect(DisplayNames.model("devin/swe-2") == "SWE-2")
    }

    @Test
    func providerSpellingsResolveThroughAliases() {
        let names = ["gemma-3-27b-it": "Gemma 3 27B IT", "claude-sonnet-4": "Claude Sonnet 4"]
        let aliases = ["gemma-3-27b": "gemma-3-27b-it"]
        #expect(DisplayNames.resolveModel("google.gemma-3-27b-it", names: names, aliases: aliases) == "Gemma 3 27B IT")
        #expect(DisplayNames.resolveModel("gemma-3-27b:free", names: names, aliases: aliases) == "Gemma 3 27B IT")
        #expect(DisplayNames.resolveModel("claude-sonnet-4@20250514", names: names, aliases: aliases) == "Claude Sonnet 4")
        #expect(DisplayNames.resolveModel("us.anthropic.claude-sonnet-4-20250514-v1:0", names: names, aliases: aliases) == "Claude Sonnet 4")
    }

    @Test
    func normalizationKeepsMeaningfulTags() {
        #expect(DisplayNames.normalizedID("llama3.3:70b") == "llama3.3-70b")
        #expect(DisplayNames.normalizedID("x-model:thinking") == "x-model-thinking")
        #expect(DisplayNames.normalizedID("cloudflare/@cf/meta/llama-guard-3-8b") == "llama-guard-3-8b")
    }

    @Test
    func localOverridesBeatBareIdNames() {
        #expect(DisplayNames.model("kimi-code/kimi-for-coding") == "Kimi For Coding")
        // Speed tiers are separate offerings, not merged.
        #expect(DisplayNames.model("kimi-for-coding-highspeed") == "Kimi For Coding HighSpeed")
    }

    @Test
    func unresolvedIdsStayExactlyAsReported() {
        let empty: [String: String] = [:]
        #expect(DisplayNames.resolveModel("Acme-Coder-2.5", names: empty, aliases: empty) == "Acme-Coder-2.5")
        #expect(DisplayNames.resolveModel("acme-high", names: empty, aliases: empty) == "acme-high")
        // Unknown ids are never merged with each other.
        #expect(DisplayNames.resolveModel("acme-2.5", names: empty, aliases: empty)
            != DisplayNames.resolveModel("acme-2-5", names: empty, aliases: empty))
        #expect(DisplayNames.model("openrouter/") == "openrouter/")
    }

    @Test
    func rollingAliasesAreNotNamedAfterTodaysTarget() {
        // models.dev names these after whatever model they currently serve.
        #expect(DisplayNames.model("devstral-medium-latest") == "devstral-medium-latest")
        #expect(DisplayNames.model("kimi-latest") == "kimi-latest")
    }

    @Test
    func dottedAndDashedVersionsResolveAlike() {
        let names = ["claude-opus-5-5": "Claude Opus 5.5", "gemini-3.8-flash": "Gemini 3.8 Flash"]
        #expect(DisplayNames.resolveModel("anthropic/claude-opus-5.5", names: names, aliases: [:]) == "Claude Opus 5.5")
        #expect(DisplayNames.resolveModel("gemini-3-8-flash", names: names, aliases: [:]) == "Gemini 3.8 Flash")
    }

    @Test
    func toolNamesUseProductCasingAndKeepUnknownIds() {
        #expect(DisplayNames.tool("claude-code") == "Claude Code")
        #expect(DisplayNames.tool("codex") == "Codex")
        #expect(DisplayNames.tool("kimi-code") == "Kimi Code")
        #expect(DisplayNames.tool("opencode") == "OpenCode")
        #expect(DisplayNames.tool("some-new-cli") == "some-new-cli")
    }

    @Test
    func familyGroupingJudgesRawIds() {
        let raw = ["Nano Banana Pro": "gemini-3-pro-image", "Claude Opus 5.5": "claude-opus-5-5"]
        let groups = groupModelsByFamily(raw.keys.sorted()) { raw[$0] ?? $0 }
        let gemini = groups.first { $0.family?.key == "gemini" }
        #expect(gemini?.models == ["Nano Banana Pro"])
        #expect(!groups.contains { $0.family == nil })
    }

    @Test
    func representativePrefersTheAliasItsFamilyRecognises() {
        // "k3" and "kimi-k3-256k" render as one label, but only the longer id
        // matches the Kimi family rule. Picking the smaller one dropped the
        // merged row out of Kimi and into 其他.
        #expect(DisplayNames.model("k3") == DisplayNames.model("kimi-k3-256k"))
        #expect(preferredFamilyRepresentative("k3", "kimi-k3-256k") == "kimi-k3-256k")
        #expect(preferredFamilyRepresentative("kimi-k3-256k", "k3") == "kimi-k3-256k")
    }

    @Test
    func representativeIsTheSmallerIdWhenNoAliasHasAFamily() {
        #expect(preferredFamilyRepresentative("zzz-alias", "aaa-alias") == "aaa-alias")
        #expect(preferredFamilyRepresentative("aaa-alias", "zzz-alias") == "aaa-alias")
    }

    @Test
    func mergedLabelStaysInTheFamilyItsRepresentativeMatches() {
        let raw = ["k3", "kimi-k3-256k"]
        let label = DisplayNames.model("k3")
        let representative = raw.reduce(String?.none) { current, candidate in
            current.map { preferredFamilyRepresentative($0, candidate) } ?? candidate
        }
        #expect(representative == "kimi-k3-256k")
        let groups = groupModelsByFamily([label]) { _ in representative ?? label }
        #expect(groups.first { $0.family?.key == "kimi" }?.models == [label])
    }

    @Test
    func toolNamesCoverEveryRegisteredSourceId() {
        // The table mirrors the web registry; an id missing here renders raw.
        #expect(DisplayNames.tool("kiki") == "Kiki")
        #expect(DisplayNames.tool("hermes") == "Hermes")
        #expect(DisplayNames.tool("codearts-agent") == "CodeArts Agent")
    }
}
