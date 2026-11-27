import Foundation
@testable import VibeUsage

/// Fixed usage for the panel renderer, close to the finalized design's
/// example figures (135a, 135b) but consistent across the cards: the models,
/// terminals and tools of one set add up to the same total. Every response is
/// built for the asked range at the fixture's clock: hourly buckets in the
/// last few hours of an hourly range, daily ones at local midnights otherwise.
enum PanelUsage {
    /// 今天 (135a): 65.5M Token, $41.20; Claude Code, Codex, Cursor on two Macs.
    case today
    /// Seven days (135b): Codex 104M among Claude Code and Cursor.
    case week
    /// 135e: the top model id has no display name from the server.
    case longNames
    /// Fifteen models on seven tools and four Macs.
    case many
    /// A period without usage.
    case none

    /// One tool × model × terminal over the whole period: millions of Token
    /// and dollars.
    private struct Line {
        let source: String
        let model: String
        let host: String
        let millions: Double
        let cost: Double
    }

    func response(for range: UsageQueryRange, now: Date) -> UsageResponse {
        let starts = Self.bucketStarts(for: range, now: now)
        var buckets: [UsageBucket] = []
        for line in lines {
            // Uneven over the period, so the curve has a shape.
            let weights = starts.indices.map { 1 + Double(($0 * 7 + line.model.count) % 5) }
            let sum = weights.reduce(0, +)
            for (start, weight) in zip(starts, weights) {
                buckets.append(Self.bucket(line, share: weight / sum, at: start))
            }
        }
        return UsageResponse(buckets: buckets, sessions: nil, hasAnyData: !buckets.isEmpty, names: Self.names)
    }

    private var lines: [Line] {
        switch self {
        case .today:
            return Self.todayLines(opus: "claude-opus-5-5")
        case .longNames:
            return Self.todayLines(opus: "claude-opus-5-5-20260514-thinking")
        case .week:
            return [
                Line(source: "codex", model: "gpt-6.2-sol", host: "MacBook-Pro", millions: 60.0, cost: 36.80),
                Line(source: "codex", model: "gpt-6.2-sol", host: "Mac-Studio", millions: 11.8, cost: 7.20),
                Line(source: "codex", model: "gpt-6.2-astra", host: "MacBook-Pro", millions: 13.9, cost: 8.50),
                Line(source: "codex", model: "gpt-6.2-astra", host: "Mac-Studio", millions: 11.0, cost: 6.80),
                Line(source: "codex", model: "gpt-6-luna", host: "MacBook-Pro", millions: 7.3, cost: 4.80),
                Line(source: "claude-code", model: "claude-opus-5-5", host: "MacBook-Pro", millions: 182.4, cost: 141.30),
                Line(source: "claude-code", model: "claude-sonnet-5-5", host: "Mac-Studio", millions: 40.2, cost: 18.60),
                Line(source: "cursor", model: "gemini-3.5-pro", host: "MacBook-Pro", millions: 21.6, cost: 7.90),
            ]
        case .many:
            let models = [
                "claude-opus-5-5", "gpt-6.2-sol", "claude-sonnet-5-5", "claude-haiku-5-5", "gemini-3.5-pro",
                "gpt-6-luna", "gpt-6.2-astra", "kimi-k3", "glm-5.1", "grok-5-code", "deepseek-v4", "qwen4-coder",
                "gemini-3.5-flash", "minimax-m3", "mistral-devstral-3",
            ]
            let sources = ["claude-code", "codex", "cursor", "opencode", "kimi-code", "zcode", "grok"]
            let hosts = ["MacBook-Pro", "Mac-Studio", "Mac-mini", "build-server-shanghai-02.internal"]
            return models.enumerated().map { index, model in
                let millions = 40 / Double(index + 1) + 0.4
                return Line(source: sources[index % sources.count], model: model, host: hosts[index % hosts.count],
                            millions: millions, cost: millions * 0.6)
            }
        case .none:
            return []
        }
    }

    /// 135a's split: models 30.9 / 16.2 / 11.4 / rest 7.0 (3.9, 2.2, 0.9);
    /// tools Claude Code 38.4, Codex 16.2, Cursor 10.9; terminals MacBook-Pro
    /// 53.7, Mac-Studio 11.8; cost $24.10 / $9.80 / $5.10 / rest $2.20.
    private static func todayLines(opus: String) -> [Line] {
        [
            Line(source: "claude-code", model: opus, host: "MacBook-Pro", millions: 30.9, cost: 24.10),
            Line(source: "claude-code", model: "claude-sonnet-5-5", host: "MacBook-Pro", millions: 3.6, cost: 1.60),
            Line(source: "claude-code", model: "claude-haiku-5-5", host: "MacBook-Pro", millions: 3.0, cost: 0.85),
            Line(source: "codex", model: "gpt-6.2-sol", host: "MacBook-Pro", millions: 16.2, cost: 9.80),
            Line(source: "cursor", model: "claude-sonnet-5-5", host: "Mac-Studio", millions: 7.8, cost: 3.50),
            Line(source: "cursor", model: "claude-haiku-5-5", host: "Mac-Studio", millions: 0.9, cost: 0.25),
            Line(source: "cursor", model: "gemini-3.5-pro", host: "Mac-Studio", millions: 2.2, cost: 0.80),
            Line(source: "claude-code", model: "gpt-6-luna", host: "Mac-Studio", millions: 0.9, cost: 0.30),
        ]
    }

    private static let names = UsageNames(
        sources: [
            "claude-code": "Claude Code", "codex": "Codex", "cursor": "Cursor", "opencode": "OpenCode",
            "kimi-code": "Kimi Code", "zcode": "ZCode", "grok": "Grok",
        ],
        models: [
            "claude-opus-5-5": "Claude Opus 5.5", "claude-sonnet-5-5": "Claude Sonnet 5.5",
            "claude-haiku-5-5": "Claude Haiku 5.5", "gpt-6.2-sol": "GPT-6.2 Sol", "gpt-6.2-astra": "GPT-6.2 Astra",
            "gpt-6-luna": "GPT-6 Luna", "gemini-3.5-pro": "Gemini 3.5 Pro", "gemini-3.5-flash": "Gemini 3.5 Flash",
            "kimi-k3": "Kimi K3", "glm-5.1": "GLM-5.1", "grok-5-code": "Grok 5 Code", "deepseek-v4": "DeepSeek V4",
            "qwen4-coder": "Qwen4 Coder", "minimax-m3": "MiniMax M3", "mistral-devstral-3": "Devstral 3",
        ],
        modelFamilies: [:],
        families: []
    )

    private static func bucketStarts(for range: UsageQueryRange, now: Date) -> [Date] {
        let calendar = Calendar.current
        if range.isHourly {
            let firstHour = floor(range.start(at: now).timeIntervalSince1970 / 3600) * 3600
            let currentHour = floor(now.timeIntervalSince1970 / 3600) * 3600
            return (0..<6).reversed()
                .map { currentHour - Double($0) * 3600 }
                .filter { $0 >= firstHour }
                .map { Date(timeIntervalSince1970: $0) }
        }
        let start = range.start(at: now)
        var days: [Date] = []
        var day = calendar.startOfDay(for: now)
        // `<` only: `>=` between two dates is ambiguous here (DateOrder.swift).
        while !(day < start) {
            days.insert(day, at: 0)
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return days
    }

    /// Cache read 95%, input 4% (a quarter of it a 5-minute cache write),
    /// output 1% (a fifth of it reasoning).
    private static func bucket(_ line: Line, share: Double, at start: Date) -> UsageBucket {
        let total = Int((line.millions * 1_000_000 * share).rounded())
        let cached = Int((Double(total) * 0.9496).rounded())
        let input = Int((Double(total) * 0.0397).rounded())
        let output = total - cached - input
        let cacheWrite = input / 4
        let reasoning = output / 5
        return UsageBucket(
            source: line.source, model: line.model, project: "vibe-usage", hostname: line.host,
            bucketStart: ISO8601DateFormatter().string(from: start),
            inputTokens: input - cacheWrite, outputTokens: output - reasoning,
            cacheCreation5mTokens: cacheWrite, cacheCreation1hTokens: nil,
            cachedInputTokens: cached, reasoningOutputTokens: reasoning,
            totalTokens: total, estimatedCost: line.cost * share
        )
    }
}
