import Foundation

struct ModelFamily: Sendable {
    let key: String
    let label: String
    let matches: @Sendable (String) -> Bool
}

let MODEL_FAMILIES: [ModelFamily] = [
    ModelFamily(key: "claude", label: "Claude") { $0.hasPrefix("claude") },
    ModelFamily(key: "gpt", label: "GPT") { $0.hasPrefix("gpt") || $0.hasPrefix("codex") },
    ModelFamily(key: "o", label: "o\u{7CFB}\u{5217}") { id in
        guard let first = id.first, first == "o", id.count > 1 else { return false }
        return id[id.index(after: id.startIndex)].isNumber
    },
    ModelFamily(key: "gemini", label: "Gemini") { $0.hasPrefix("gemini") },
    ModelFamily(key: "deepseek", label: "DeepSeek") { $0.hasPrefix("deepseek") },
    ModelFamily(key: "qwen", label: "Qwen") { $0.hasPrefix("qwen") },
    ModelFamily(key: "glm", label: "GLM") { $0.hasPrefix("glm") },
    ModelFamily(key: "kimi", label: "Kimi") { $0.hasPrefix("kimi") || $0.hasPrefix("moonshot") },
    ModelFamily(key: "minimax", label: "MiniMax") { $0.hasPrefix("minimax") },
    ModelFamily(key: "doubao", label: "Doubao") { $0.hasPrefix("doubao") },
]

struct ModelGroup {
    let family: ModelFamily?
    let models: [String]
}

/// The family a raw model id belongs to, ignoring a provider prefix
/// ("anthropic/claude-opus-4-20250514" is Claude). Display names drop those
/// prefixes, so callers that hold only a display name judge its family from
/// the raw id behind it — and a merged label can have several, so the choice
/// of which one to judge matters (see `FilterTagsView.modelRawIDs`).
func modelFamily(of rawID: String) -> ModelFamily? {
    let lower = rawID.lowercased()
    let base = lower.firstIndex(of: "/").map { String(lower[lower.index(after: $0)...]) } ?? lower
    return MODEL_FAMILIES.first { $0.matches(base) }
}

/// Picks which raw id represents a display name when several raw ids merge into
/// it and the family rules have to judge one of them.
///
/// The choice is not cosmetic: `k3` and `kimi-k3-256k` both render as
/// "Kimi K3", but `k3` matches no family, so taking the lexicographically
/// smallest alias dropped the merged row into 其他 even though that same model
/// was listed under Kimi before the merge. Prefer a recognised family, then the
/// smaller id so the pick stays deterministic.
func preferredFamilyRepresentative(_ current: String, _ candidate: String) -> String {
    let currentKnown = modelFamily(of: current) != nil
    let candidateKnown = modelFamily(of: candidate) != nil
    if currentKnown != candidateKnown { return candidateKnown ? candidate : current }
    return candidate < current ? candidate : current
}

/// `familyID` maps an entry to the raw model id its family is judged by.
/// Display names drop vendor prefixes ("Nano Banana", "Seed 2.0 Pro"), so
/// callers grouping display names pass their raw ids here.
func groupModelsByFamily(_ models: [String], familyID: (String) -> String = { $0 }) -> [ModelGroup] {
    var familyMap: [String: [String]] = [:]
    var others: [String] = []

    for family in MODEL_FAMILIES {
        familyMap[family.key] = []
    }

    for model in models {
        if let family = modelFamily(of: familyID(model)) {
            familyMap[family.key]?.append(model)
        } else {
            others.append(model)
        }
    }

    var result: [ModelGroup] = []

    for family in MODEL_FAMILIES {
        let familyModels = familyMap[family.key] ?? []
        if !familyModels.isEmpty {
            result.append(ModelGroup(family: family, models: familyModels))
        }
    }

    if !others.isEmpty {
        result.append(ModelGroup(family: nil, models: others))
    }

    return result
}
