import Foundation

struct UsageBucket: Codable, Identifiable, Equatable {
    var id: String {
        "\(bucketStart)-\(source)-\(model)-\(project)-\(hostname)"
    }

    let source: String
    let model: String
    let project: String
    let hostname: String
    let bucketStart: String
    let inputTokens: Int
    let outputTokens: Int
    /// Not yet emitted by the sync pipeline (collector and server track only
    /// cache reads); optional so decoding keeps working once it appears.
    let cacheCreationInputTokens: Int?
    let cachedInputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int
    let estimatedCost: Double?

    /// Total token volume, matching the web dashboard and ccusage-style totals:
    /// input + output + reasoning + cached input.
    var computedTotal: Int {
        inputTokens + outputTokens + reasoningOutputTokens + cachedInputTokens
    }

    /// Absolute instant parsed from the API's ISO-8601 bucket timestamp.
    var date: Date? {
        Formatters.dateFromISO8601(bucketStart)
    }

    /// Gregorian calendar-day key in the viewer's timezone.
    var dayKey: String {
        dayKey(in: .current)
    }

    func dayKey(in timeZone: TimeZone) -> String {
        Formatters.localDayKey(bucketStart, timeZone: timeZone)
    }

    /// Hour string (yyyy-MM-ddTHH) for hourly grouping
    var hourKey: String {
        String(bucketStart.prefix(13))
    }
}

struct UsageResponse: Codable {
    let buckets: [UsageBucket]
    let sessions: [UsageSession]?
    let hasAnyData: Bool
    /// Optional so a server that predates the field still decodes: the lookups
    /// fall back to the raw id, which is what the app showed before.
    let names: UsageNames?
}

/// Display names and family rows supplied by the server alongside the usage.
///
/// Naming has exactly one implementation, in `vibe-cafe`: it resolves every id
/// against its models.dev snapshot and its source registry (`USAGE_SOURCES`,
/// the list the ingest endpoint validates) and rides the answer on the response
/// the app already makes. The app therefore keeps **no** id→name table and no
/// matching rules of its own — an id the server could not resolve simply has no
/// entry here, and the app shows it exactly as reported. The Windows app and the
/// dashboard read the same fields, so the three agree by construction instead of
/// by three hand-synced tables.
struct UsageNames: Codable {
    /// Upload source id → product name ("claude-code" → "Claude Code").
    let sources: [String: String]
    /// Raw model id as a tool reported it → official name.
    let models: [String: String]
    /// Raw model id → family key ("k3" → "kimi").
    let modelFamilies: [String: String]
    /// The family rows `modelFamilies` refers to, in the server's order.
    let families: [UsageFamily]
}

struct UsageFamily: Codable, Identifiable, Equatable {
    let key: String
    let label: String
    let provider: String

    var id: String { key }
}

/// One row of the model filter: a family the server named, and the display names
/// that belong to it. `key == "other"` is the bucket for names the server could
/// not place.
struct ModelFilterGroup: Identifiable {
    let key: String
    let label: String
    let models: [String]

    var id: String { key }
}
