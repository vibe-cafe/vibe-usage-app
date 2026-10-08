import Foundation

/// Human-facing names for the raw identifiers the sync pipeline reports.
///
/// Raw ids stay the source of truth everywhere (API, filters on tools/projects,
/// uploads); this only decides what the dashboard shows. Models resolve to one
/// display name per underlying model, so reasoning-effort, context-window and
/// router-prefix variants of the same model share a label and are merged.
///
/// Only names backed by the catalog or the tables below are shown. An id that
/// cannot be resolved with confidence is displayed exactly as reported: a raw
/// id is never wrong, a guessed name or a guessed merge can be.
enum DisplayNames {

    // MARK: - Tools

    /// Official product names. This table mirrors `USAGE_SOURCES` in the web
    /// repo (`vibe-cafe/apps/web/src/lib/usage-sources.ts`), which is the
    /// registry the ingest endpoint validates against — not the CLI's own
    /// tools table, which additionally lists tools the backend has not
    /// registered (and spells a few differently). Keep the two in step: an id
    /// missing here renders as its raw lowercase id.
    static let toolNames: [String: String] = [
        "alma": "Alma",
        "amp": "Amp",
        "antigravity": "Antigravity",
        "claude-code": "Claude Code",
        "cline": "Cline",
        "codearts-agent": "CodeArts Agent",
        "codebuddy": "CodeBuddy",
        "codex": "Codex",
        "cola": "Cola",
        "copilot-cli": "Copilot CLI",
        "craft-agent": "CraftAgent",
        "cursor": "Cursor",
        "devin": "Devin",
        "dimagent": "DimAgent",
        "droid": "Droid",
        "dsh": "DeepSeek Harness",
        "gemini-cli": "Gemini CLI",
        "grok": "Grok",
        "hermes": "Hermes",
        "kiki": "Kiki",
        "kimi-code": "Kimi Code",
        "kiro": "Kiro",
        "mcode": "MiniMax Code",
        "mimocode": "MiMoCode",
        "omp": "Oh My Pi",
        "openclaw": "OpenClaw",
        "opencode": "OpenCode",
        "pi-coding-agent": "pi",
        "qoder": "Qoder",
        "qoder-cn": "Qoder CN",
        "qwen-code": "Qwen Code",
        "roo-code": "Roo Code",
        "trae-cli": "Trae CLI",
        "workbuddy": "WorkBuddy",
        "zcode": "ZCode",
    ]

    static func tool(_ raw: String) -> String {
        toolNames[raw.lowercased()] ?? raw
    }

    // MARK: - Models

    /// Names models.dev lacks or spells as the bare id. Takes precedence over
    /// the generated catalog.
    static let modelOverrides: [String: String] = [
        "swe-2": "SWE-2",
        // A plan alias that has pointed at several Kimi models over time, so
        // it keeps its own name instead of following today's target.
        "kimi-for-coding": "Kimi For Coding",
        "kimi-for-coding-highspeed": "Kimi For Coding HighSpeed",
    ]

    /// Short ids some tools report that models.dev does not list.
    static let modelAliases: [String: String] = [
        "fable-5": "claude-fable-5",
    ]

    /// Trailing variant markers. Stripped only when what is left is a known
    /// model, so "qwen3-max" or "grok-4-fast" keep their own names.
    static let variantSuffixes: [String] = [
        // reasoning effort / thinking mode
        "minimal", "none", "low", "medium", "high", "xhigh", "max", "thinking",
        // serving-side tags Gemini reports per response
        "exp-a", "exp-b", "exp-c", "exp", "n",
        // quantization and hosting variants of the same weights
        "nvfp4", "fp4", "fp8", "fp16", "bf16", "int4", "int8", "awq", "tee", "free",
    ].sorted { $0.count > $1.count }

    /// `model:tag` tags that only mark a pricing or routing tier.
    static let droppedTags: Set<String> = [
        "free", "beta", "exacto", "nitro", "floor", "extended", "online",
    ]

    private static let vendorPrefix =
        #"^(anthropic|google|meta|mistral|amazon|deepseek|moonshotai|openai|qwen|minimax|xiaomi|zai|cohere|nvidia|ai21|writer|us|eu|apac|global|jp|au)\."#

    /// Suffixes that never distinguish models: release dates, Bedrock
    /// revisions, gateway expiry tags and context window sizes.
    private static let noisePatterns = [
        #"-\d{8}-v\d+$"#,         // claude-3-5-sonnet-20240620-v1
        #"-\d{8}$"#,               // claude-haiku-4-5-20251001
        #"-\d{4}-\d{2}-\d{2}$"#, // gpt-4o-2024-08-06
        #"-expires-on-\d+$"#,      // deepseek-v4.1-flash-expires-on-0910
        #"-\d+[km]$"#,             // k3-256k, claude-sonnet-5-1m
    ]

    private static let cache = DisplayNameCache()

    static func model(_ raw: String) -> String {
        if let cached = cache.value(for: raw) { return cached }
        let resolved = resolveModel(raw)
        cache.store(resolved, for: raw)
        return resolved
    }

    static func resolveModel(
        _ raw: String,
        names: [String: String] = ModelCatalog.names,
        aliases: [String: String] = ModelCatalog.aliases
    ) -> String {
        let id = normalizedID(raw)
        guard !id.isEmpty else { return raw }
        if let name = lookup(id, names: names, aliases: aliases) { return name }

        var base = id
        while let suffix = variantSuffixes.first(where: { base.hasSuffix("-" + $0) && base.count > $0.count + 1 }) {
            base = stripNoise(String(base.dropLast(suffix.count + 1)))
            if let name = lookup(base, names: names, aliases: aliases) { return name }
        }
        return raw
    }

    /// Lowercased id without router prefix, routing tag, region, vendor
    /// namespace or noise suffixes. Mirrored by `normalize` in
    /// scripts/generate-model-catalog.py, which keys the alias table with it.
    static func normalizedID(_ raw: String) -> String {
        var id = raw.trimmingCharacters(in: .whitespaces).lowercased()
        // Router / provider paths: "kimi-code/k3-256k", "cloudflare/@cf/meta/x".
        if let slash = id.lastIndex(of: "/") {
            id = String(id[id.index(after: slash)...])
        }
        // "x:free" drops a routing tier; "llama3.3:70b" keeps the size.
        if let colon = id.firstIndex(of: ":") {
            let base = String(id[..<colon])
            let tag = String(id[id.index(after: colon)...])
            let dropTag = tag.allSatisfy(\.isNumber) || droppedTags.contains(tag)
            id = dropTag ? base : base + "-" + tag.replacingOccurrences(of: ":", with: "-")
        }
        // Vertex region / version: "claude-sonnet-4@20250514".
        if let at = id.firstIndex(of: "@"), at > id.startIndex {
            id = String(id[..<at])
        }
        // Bedrock namespaces: "us.anthropic.claude-…", "qwen.qwen3-…".
        while let range = id.range(of: vendorPrefix, options: .regularExpression) {
            id.removeSubrange(range)
        }
        return stripNoise(id)
    }

    private static func stripNoise(_ id: String) -> String {
        var result = id
        var changed = true
        while changed {
            changed = false
            for pattern in noisePatterns {
                if let range = result.range(of: pattern, options: .regularExpression),
                   range.lowerBound > result.startIndex {
                    result.removeSubrange(range)
                    changed = true
                }
            }
        }
        return result
    }

    private static func lookup(_ id: String, names: [String: String], aliases: [String: String]) -> String? {
        for candidate in [id, dashedVersion(id), dottedVersion(id)] {
            let key = modelAliases[candidate] ?? candidate
            if let name = modelOverrides[key] ?? names[key] { return name }
            if let target = aliases[key], let name = modelOverrides[target] ?? names[target] { return name }
        }
        return nil
    }

    /// "claude-opus-5.5" → "claude-opus-5-5"
    private static func dashedVersion(_ id: String) -> String {
        id.replacingOccurrences(of: #"(?<=\d)\.(?=\d)"#, with: "-", options: .regularExpression)
    }

    /// "gemini-3-8-flash" → "gemini-3.8-flash", "qwen3-8-flash" → "qwen3.8-flash"
    private static func dottedVersion(_ id: String) -> String {
        id.replacingOccurrences(of: #"(?<=\d)-(?=\d(?:-|$))"#, with: ".", options: .regularExpression)
    }
}

/// Resolution runs on every filter pass over the buckets, so memoize it.
private final class DisplayNameCache: @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    func value(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func store(_ value: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}
