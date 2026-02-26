import Foundation

/// HTTP client for vibecafe.ai API (authenticated with API Key)
struct APIClient: Sendable {
    let baseURL: String
    let apiKey: String

    /// Fetch usage buckets for the dashboard
    func fetchUsage(days: Int) async throws -> UsageResponse {
        guard let url = URL(string: "\(baseURL)/api/usage?days=\(days)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            return try decoder.decode(UsageResponse.self, from: data)
        case 401:
            throw APIError.unauthorized
        default:
            throw APIError.httpError(httpResponse.statusCode)
        }
    }

    /// Validate API key by fetching usage data (GET /api/usage?days=1)
    /// Returns the response data if valid, so we can use it immediately.
    func validateKeyAndFetch() async throws -> UsageResponse {
        // Reuse fetchUsage — 401 means invalid key
        return try await fetchUsage(days: 1)
    }

    enum APIError: LocalizedError {
        case invalidURL
        case invalidResponse
        case unauthorized
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "URL 无效"
            case .invalidResponse: "服务器响应异常"
            case .unauthorized: "API Key 无效"
            case .httpError(let code): "HTTP 错误 \(code)"
            }
        }
    }
}
