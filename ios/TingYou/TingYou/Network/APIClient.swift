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
    /// build 20 必修 5：传输层错误（URLError，非状态码）重试的指数退避阶梯。
    /// 首发不延迟——只有重试之间等待；阶梯用尽后取最后一档。
    var transportBackoffSecs: [TimeInterval] = [0.5, 1.0, 2.0]

    /// build 22 r2 · 真机反馈「加载失败：The network connection was lost.」：
    /// 连接级错误的自动重试上限，独立于状态码重试预算——固定最多 2 次重试（共 3 次尝试），
    /// 退避用 transportBackoffSecs 前两档（0.5s / 1s）。
    /// 不与频控退避（适配层 MsrcAdapter 3s/8s）叠加：频控等待发生在适配层、连接退避发生在
    /// 请求层，两层顺序执行、线性相加，不叠成指数级放大。
    var connectionMaxRetries: Int = 2

    static let msrc = RetryConfig(maxRetries: 1, backoffSecs: [1.5])
    static let mekui = RetryConfig(maxRetries: 2, backoffSecs: [2.5, 8.0])
    static let standard = RetryConfig(maxRetries: 1, backoffSecs: [1.5])

    /// build 22 r2：连接级错误集合（诊断结论：真机到 ting08 服务器（182.237.1.188）
    /// 的网络路径被运营商/路由层瞬时断开，-1005 是其典型报错）。
    /// - networkConnectionLost(-1005)：连接被中途断开——本次修复的直接目标
    /// - timedOut(-1001)：连接/请求超时——同属路径级瞬时故障，重试可能走新路径恢复
    /// - cannotConnectToHost(-1004)：无法建立连接——服务端诊断正常时多为路径抖动
    /// - notConnectedToInternet(-1009)：无网络——build 20 传输层重试已覆盖此语义，保留
    /// - build 24（build 22 质检 P2-1）：DNS 瞬时错误补入——
    ///   cannotFindHost(-1003)：域名解析失败（DNS 抖动时瞬时出现，重试可能命中新解析）
    ///   dnsLookupFailed(-1006)：DNS 查找失败（同上，移动网络切换/LocalDNS 抖动典型）
    /// 其余 URLError（用户取消、badServerResponse 等）一律不重试、直接抛出。
    static let connectionErrorCodes: Set<URLError.Code> = [
        .networkConnectionLost,
        .timedOut,
        .cannotConnectToHost,
        .notConnectedToInternet,
        .cannotFindHost,
        .dnsLookupFailed,
    ]

    /// 该错误是否属于连接级（可自动重试）错误。
    static func isConnectionError(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return connectionErrorCodes.contains(e.code)
    }

    func backoff(forAttempt attempt: Int) -> TimeInterval {
        guard !backoffSecs.isEmpty else { return 1.0 }
        return backoffSecs[min(attempt, backoffSecs.count - 1)]
    }

    /// 传输层错误重试的退避时长（attempt 为 0 基重试序号）。
    func transportBackoff(forAttempt attempt: Int) -> TimeInterval {
        guard !transportBackoffSecs.isEmpty else { return 0 }
        return transportBackoffSecs[min(attempt, transportBackoffSecs.count - 1)]
    }
}

/// build 22 r2：连接级重试耗尽后的可诊断错误。
/// 真机原文案「加载失败：The network connection was lost.」让用户无法区分是网络问题
/// 还是服务器问题；升级文案直接说明这是网络层中断且已自动重试过，UI 层经
/// `localizedDescription` 渲染即可透出，无需改动各 ViewModel。
struct ConnectionRetryExhaustedError: LocalizedError {
    let underlying: URLError

    var errorDescription: String? {
        "网络连接中断（已自动重试仍失败），请检查网络后重试"
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

    /// 统一执行入口（所有 fetchHTML / postFormForString / fetchJSON / fetchData 唯一出口）。
    /// - 状态码重试：可重试状态码（502/503/504）且还在 config 预算内 → 退避后重试；
    ///   其余非 200 直接失败。状态码判定必须在 do-catch 之外：非 200 抛出的 URLError 若
    ///   落在 catch 里会被当成传输错误重试 → 404 也被重发（testExecuteDoesNotRetryOn404 回归）。
    /// - build 22 r2 · 连接级错误自动重试：仅 URLError 的 -1005/-1001/-1004/-1009 四类
    ///   连接级错误重试，固定最多 2 次（共 3 次尝试），退避 0.5s / 1s；其余错误直接抛出。
    ///   重试即「新建连接」：连接被断开后 URLSession 连接池中的失效连接不会复用，
    ///   重发请求即建立全新 TCP/TLS 连接（无需换 session）。
    func execute(_ request: URLRequest, retry: RetryConfig = .standard) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error = URLError(.badServerResponse)
        // 总尝试次数取状态码重试与连接重试预算的较大者：连接级错误固定最多 3 次尝试，
        // 不受调用方 config 的状态码预算（msrc=1 / mekui=2）限制。
        let attempts = max(retry.maxRetries, retry.connectionMaxRetries) + 1
        for attempt in 0..<attempts {
            let data: Data
            let http: HTTPURLResponse
            do {
                let (raw, resp) = try await session.data(for: request)
                guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                data = raw
                http = h
            } catch {
                lastError = error
                // build 22 r2：仅连接级错误重试；其余（用户取消、解析失败、
                // 证书固定失败等）直接抛出，不重试。
                guard RetryConfig.isConnectionError(error) else { throw error }
                if attempt >= retry.connectionMaxRetries {
                    // 重试耗尽：升级为可诊断文案（网络层问题，已自动重试过），
                    // 不再裸抛「The network connection was lost.」。
                    // isConnectionError 已保证此处是 URLError，?? 兜底仅为防御式写法。
                    throw ConnectionRetryExhaustedError(
                        underlying: error as? URLError ?? URLError(.networkConnectionLost))
                }
                try await Task.sleep(nanoseconds: UInt64(retry.transportBackoff(forAttempt: attempt) * 1_000_000_000))
                continue
            }
            if HttpRetryPolicy.isRetryable(http.statusCode) && attempt < retry.maxRetries {
                try await Task.sleep(nanoseconds: UInt64(retry.backoff(forAttempt: attempt) * 1_000_000_000))
                continue
            }
            guard http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return (data, http)
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

    /// build 21 · 反馈 2（Bug B）：响应体按网页声明的字符集解码，不再静默 utf8 ?? ""。
    /// 解码链：Content-Type 的 charset 参数 → utf-8 → gb18030（GBK 系老站）→ ISO-8859-1 兜底（永不失败）。
    /// 静默返回空串会掩盖乱码与丢数据；本函数保证「尽力解出可读文本」。
    /// （Swift 的 String.Encoding 无 gb18030 静态成员，经 CF 桥接构造——与 big5 同模式。）
    static let gb18030Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    static func decodeBody(_ data: Data, contentType: String?) -> String {
        // 1) Content-Type 里声明的 charset 优先
        var declared: String.Encoding? = nil
        if let contentType,
           let range = contentType.range(of: "charset=", options: .caseInsensitive) {
            let raw = contentType[range.upperBound...]
                .prefix { !$0.isWhitespace && $0 != ";" && $0 != "\"" }
                .trimmingCharacters(in: .whitespaces)
            declared = Self.encoding(forName: String(raw))
        }
        if let declared, let s = String(data: data, encoding: declared), !s.isEmpty {
            return s
        }
        // 2) utf-8 → gb18030 → ISO-8859-1（逐级探测；gb18030 向下兼容 GBK/GB2312）
        for enc in [String.Encoding.utf8, Self.gb18030Encoding] {
            if let s = String(data: data, encoding: enc), !s.isEmpty { return s }
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// charset 名称 → CFStringEncoding（常用集，未识别返回 nil 走探测链）。
    private static func encoding(forName name: String) -> String.Encoding? {
        let known: [String: String.Encoding] = [
            "utf-8": .utf8, "utf8": .utf8,
            "gb18030": gb18030Encoding,
            "gbk": gb18030Encoding,
            "gb2312": gb18030Encoding,   // GB2312 是 GBK 子集，gb18030 可解
            "big5": String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue))),
            "big5-hkscs": String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue))),
            "shift_jis": .shiftJIS,
            "euc-jp": .japaneseEUC,
            "iso-8859-1": .isoLatin1, "latin1": .isoLatin1, "ascii": .ascii,
            "windows-1252": .windowsCP1252,
            "windows-1251": .windowsCP1251,
        ]
        return known[name.lowercased()]
    }

    /// 浏览器 UA 的 GET，返回字符串体。headers 可覆盖默认（Referer / Cookie / xt 等）。
    func fetchHTML(_ urlString: String, headers: [String: String] = [:], retry: RetryConfig = .standard) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        }
        let (data, http) = try await execute(req, retry: retry)
        return Self.decodeBody(data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
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
        let (data, http) = try await execute(req, retry: retry)
        return Self.decodeBody(data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
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
