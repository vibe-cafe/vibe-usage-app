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
        let lower = familyID(model).lowercased()
        // Handle provider prefixes like "anthropic/claude-opus-4-20250514"
        let base: String
        if let slashIndex = lower.firstIndex(of: "/") {
            base = String(lower[lower.index(after: slashIndex)...])
        } else {
            base = lower
        }

        if let family = MODEL_FAMILIES.first(where: { $0.matches(base) }) {
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
