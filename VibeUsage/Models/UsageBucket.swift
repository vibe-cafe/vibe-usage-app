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
    let cacheCreationInputTokens: Int
    let cachedInputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int
    let estimatedCost: Double?

    /// Full billable total (input + cacheCreation + output + reasoning)
    var computedTotal: Int {
        inputTokens + cacheCreationInputTokens + outputTokens + reasoningOutputTokens
    }

    /// Date parsed from bucketStart ISO string
    var date: Date? {
        ISO8601DateFormatter().date(from: bucketStart)
    }

    /// Day string (yyyy-MM-dd) for grouping
    var dayKey: String {
        String(bucketStart.prefix(10))
    }

    /// Hour string (yyyy-MM-ddTHH) for hourly grouping
    var hourKey: String {
        String(bucketStart.prefix(13))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        model = try container.decode(String.self, forKey: .model)
        project = try container.decode(String.self, forKey: .project)
        hostname = try container.decode(String.self, forKey: .hostname)
        bucketStart = try container.decode(String.self, forKey: .bucketStart)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        cachedInputTokens = try container.decode(Int.self, forKey: .cachedInputTokens)
        reasoningOutputTokens = try container.decode(Int.self, forKey: .reasoningOutputTokens)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        estimatedCost = try container.decodeIfPresent(Double.self, forKey: .estimatedCost)
    }
}

struct UsageResponse: Codable {
    let buckets: [UsageBucket]
    let sessions: [UsageSession]?
    let hasAnyData: Bool
}
