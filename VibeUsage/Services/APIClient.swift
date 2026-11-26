import Foundation

/// Authenticated usage client for vibefriends.com or the configured server.
struct APIClient: Sendable {
    let server: UsageServer
    let apiKey: String

    /// Fetch usage buckets for the dashboard.
    func fetchUsage(range: UsageQueryRange) async throws -> UsageResponse {
        guard let endpoint = server.url(for: "api/usage"),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        var queryItems = (components.queryItems ?? []) + range.queryItems
        queryItems.append(URLQueryItem(name: "tz", value: TimeZone.current.identifier))
        components.queryItems = queryItems
        guard let url = components.url else { throw APIError.invalidURL }

        debugLog("[APIClient] GET \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            debugLog("[APIClient] ERROR: invalid response type")
            throw APIError.invalidResponse
        }

        debugLog("[APIClient] Status: \(httpResponse.statusCode), bytes: \(data.count)")

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
        return try await fetchUsage(range: .days(1))
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

enum UsageQueryRange: Sendable, Equatable {
    case days(Int)
    case from(Date)
    case custom(from: Date, to: Date)

    var queryItems: [URLQueryItem] {
        switch self {
        case .days(let days):
            [URLQueryItem(name: "days", value: String(days))]
        case .from(let from):
            [URLQueryItem(name: "from", value: Self.isoString(from))]
        case .custom(let from, let to):
            [
                URLQueryItem(name: "from", value: Self.dateString(from)),
                URLQueryItem(name: "to", value: Self.dateString(to)),
            ]
        }
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Device authorization flow (unauthenticated)

struct DeviceCodeResponse: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String
    let expiresIn: Int
    let interval: Int
}

struct DevicePollResponse: Decodable, Sendable {
    let apiKey: String?
    let apiUrl: String?
    let error: String?

    func linkedServer(fallingBackTo requestedServer: UsageServer) -> UsageServer {
        guard let apiUrl, !apiUrl.isEmpty else { return requestedServer }
        return UsageServer(apiUrl)
    }
}

enum DeviceFlowError: LocalizedError {
    case denied
    case expired
    case network(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .denied: "你拒绝了链接请求。"
        case .expired: "验证码已过期，请重新登录。"
        case .network(let msg): "网络错误：\(msg)"
        case .server(let msg): "服务端错误：\(msg)"
        }
    }
}

func requestDeviceCode(server: UsageServer, clientName: String, hostname: String?) async throws -> DeviceCodeResponse {
    guard let url = server.url(for: "api/usage/device/code") else {
        throw APIClient.APIError.invalidURL
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 15
    var body: [String: String] = ["clientName": clientName]
    if let hostname { body["hostname"] = hostname }
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else {
        throw APIClient.APIError.invalidResponse
    }
    guard http.statusCode == 200 else {
        throw APIClient.APIError.httpError(http.statusCode)
    }
    return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
}

func pollDeviceCode(server: UsageServer, deviceCode: String) async throws -> DevicePollResponse {
    guard let url = server.url(for: "api/usage/device/poll") else {
        throw APIClient.APIError.invalidURL
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 15
    req.httpBody = try JSONSerialization.data(withJSONObject: ["deviceCode": deviceCode])

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else {
        throw APIClient.APIError.invalidResponse
    }
    // 200 covers success + pending/denied/expired (RFC 8628 style).
    // 410 is "already delivered, never replay".
    if http.statusCode == 200 || http.statusCode == 410 {
        return try JSONDecoder().decode(DevicePollResponse.self, from: data)
    }
    throw APIClient.APIError.httpError(http.statusCode)
}
