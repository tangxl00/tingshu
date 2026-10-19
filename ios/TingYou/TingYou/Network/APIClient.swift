import Foundation

/// 重试策略（P0-5）：502/503/504 瞬时故障退避重试，语义与安卓 MsrcHttp/MekuiHttp 对齐。
enum HttpRetryPolicy {
    static let retryableStatuses: Set<Int> = [502, 503, 504]

    /// 该状态码是否可重试（仅网关类瞬时故障；404/500 等直接失败，与安卓一致）
    static func isRetryable(_ statusCode: Int) -> Bool {
        retryableStatuses.contains(statusCode)
    }
}

/// 重试配置：安卓基线 MsrcHttp=1 次/1.5s；MekuiHttp=2 次/[2.5s, 8s]。
struct RetryConfig: Sendable {
    let maxRetries: Int
    let backoffSecs: [TimeInterval]

    static let msrc = RetryConfig(maxRetries: 1, backoffSecs: [1.5])
    static let mekui = RetryConfig(maxRetries: 2, backoffSecs: [2.5, 8.0])
    static let standard = RetryConfig(maxRetries: 1, backoffSecs: [1.5])

    func backoff(forAttempt attempt: Int) -> TimeInterval {
        guard !backoffSecs.isEmpty else { return 1.0 }
        return backoffSecs[min(attempt, backoffSecs.count - 1)]
    }
}

actor APIClient {
    static let baseURL = "https://tingyou.fm/listening-api/"
    static let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
            self.session = URLSession(configuration: config,
                                      delegate: PinningURLSessionDelegate(),
                                      delegateQueue: nil)
        }
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: - 带重试的执行核心（P0-5：502/503/504 按策略退避重试）

    /// 统一执行入口：可重试状态码且还有次数 → 退避后重试；其余非 200 直接失败。
    func execute(_ request: URLRequest, retry: RetryConfig = .standard) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error = URLError(.badServerResponse)
        for attempt in 0...retry.maxRetries {
            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await session.data(for: request)
            } catch {
                // 传输层错误（URLError）：按策略退避重试（与安卓 IOException 语义一致）
                lastError = error
                if attempt >= retry.maxRetries { throw error }
                try await Task.sleep(nanoseconds: UInt64(retry.backoff(forAttempt: attempt) * 1_000_000_000))
                continue
            }
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 200 { return (data, http) }
            if HttpRetryPolicy.isRetryable(http.statusCode) && attempt < retry.maxRetries {
                try await Task.sleep(nanoseconds: UInt64(retry.backoff(forAttempt: attempt) * 1_000_000_000))
                continue
            }
            // 非可重试状态（404/500 等）或重试预算耗尽：直接失败，绝不再发请求
            throw URLError(.badServerResponse)
        }
        throw lastError
    }

    // MARK: - 听友 FM JSON API

    func get<T: Decodable>(_ path: String, queries: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(string: Self.baseURL + path)!
        if !queries.isEmpty {
            comps.queryItems = queries.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.setValue("Asia/Shanghai", forHTTPHeaderField: "x-listening-timezone")
        let (data, _) = try await execute(req)
        return try decoder.decode(T.self, from: data)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var req = URLRequest(url: URL(string: Self.baseURL + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Asia/Shanghai", forHTTPHeaderField: "x-listening-timezone")
        req.httpBody = try encoder.encode(body)
        let (data, _) = try await execute(req)
        return try decoder.decode(T.self, from: data)
    }

    func postForm<T: Decodable>(_ path: String, fields: [String: String]) async throws -> T {
        var req = URLRequest(url: URL(string: Self.baseURL + path)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Asia/Shanghai", forHTTPHeaderField: "x-listening-timezone")
        req.httpBody = formBody(fields)
        let (data, _) = try await execute(req)
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - 通用抓取（供多音源适配器复用，出站白名单自检由调用方负责）

    /// 浏览器 UA 的 GET，返回字符串体。headers 可覆盖默认（Referer / Cookie / xt 等）。
    func fetchHTML(_ urlString: String, headers: [String: String] = [:], retry: RetryConfig = .standard) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        }
        let (data, _) = try await execute(req, retry: retry)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 表单 POST（自定义头），返回字符串体（api-getneoplay / ting08 搜索用）。
    func postFormForString(_ urlString: String, fields: [String: String], headers: [String: String] = [:], retry: RetryConfig = .standard) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = formBody(fields)
        let (data, _) = try await execute(req, retry: retry)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// JSON GET（mekui ecmsapi 用：非 200 / 非 JSON 都抛错）。
    func fetchJSON(_ urlString: String, headers: [String: String] = [:], retry: RetryConfig = .mekui) async throws -> [String: Any] {
        let body = try await fetchHTML(urlString, headers: headers, retry: retry)
        guard let data = body.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return obj
    }

    func fetchData(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        let (data, _) = try await execute(req)
        return data
    }

    private func formBody(_ fields: [String: String]) -> Data? {
        fields.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&").data(using: .utf8)
    }
}
