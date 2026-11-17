import Foundation

struct BalanceInfo: Codable, Identifiable {
    let currency: String
    let total_balance: String
    let granted_balance: String
    let topped_up_balance: String

    var id: String { currency }

    var total: Double { Double(total_balance) ?? 0 }
    var granted: Double { Double(granted_balance) ?? 0 }
    var toppedUp: Double { Double(topped_up_balance) ?? 0 }

    var symbol: String { currency == "CNY" ? "¥" : "$" }
}

struct BalanceResponse: Codable {
    let is_available: Bool
    let balance_infos: [BalanceInfo]
}

enum BalanceError: LocalizedError {
    case noKey
    case unauthorized
    case http(Int, String)
    case network(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .noKey: return "还没有设置 API Key"
        case .unauthorized: return "API Key 无效（401）"
        case let .http(code, body): return "服务端返回 \(code)：\(body)"
        case let .network(message): return "网络错误：\(message)"
        case .decoding: return "余额响应解析失败"
        }
    }
}

/// GET /user/balance（不计费）
enum BalanceClient {
    static func fetch(apiKey: String) async throws -> BalanceResponse {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            throw BalanceError.network("URL 非法")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BalanceError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BalanceError.network("无 HTTP 响应")
        }
        if http.statusCode == 401 { throw BalanceError.unauthorized }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw BalanceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw BalanceError.decoding
        }
    }
}
