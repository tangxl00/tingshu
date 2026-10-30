import Foundation

/// build 50 · 云同步九端点 HTTP 客户端。
/// - baseURL 为已部署的 tingshu-sync 云函数网关地址（与 PC 端同一服务）
/// - 会话复用 PinningURLSessionDelegate（证书固定 + 域名白名单 fail-closed，
///   tingshu-d2gjera4688800c8e.service.tcloudbase.com 已加入白名单）
/// - 单次请求不内建重试：40003 由 SyncEngine 做 refresh 后重试一次；
///   网络超时 / 50001 由上层给「首次登录云端建表可能超 3 秒」的友好重试提示
final class SyncCloudClient: @unchecked Sendable {
    static let baseURL = URL(string: "https://tingshu-d2gjera4688800c8e.service.tcloudbase.com")!

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: config,
                                      delegate: PinningURLSessionDelegate(),
                                      delegateQueue: nil)
        }
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: - 九端点（契约 §2）

    func config() async throws -> SyncConfigData {
        try await get("auth/v1/config")
    }

    func requestCode(email: String) async throws -> SyncCodeData {
        try await post("auth/v1/code", body: SyncCodeRequest(email: email))
    }

    func login(email: String, code: String, deviceId: String,
               deviceName: String = "iPhone", platform: String = "ios") async throws -> SyncLoginData {
        try await post("auth/v1/login", body: SyncLoginRequest(
            email: email, code: code, deviceId: deviceId,
            deviceName: deviceName, platform: platform))
    }

    func refresh(refreshToken: String) async throws -> SyncRefreshData {
        try await post("auth/v1/refresh", body: SyncRefreshRequest(refreshToken: refreshToken))
    }

    func logout(accessToken: String) async throws {
        let _: SyncOkData = try await post("auth/v1/logout", body: SyncEmptyRequest(), accessToken: accessToken)
    }

    func me(accessToken: String) async throws -> SyncMeData {
        try await get("account/v1/me", accessToken: accessToken)
    }

    func pull(accessToken: String, sinceSeq: Int64) async throws -> SyncPullData {
        try await post("sync/v1/pull", body: SyncPullRequest(sinceSeq: sinceSeq), accessToken: accessToken)
    }

    func push(accessToken: String, ops: [SyncPushOp]) async throws -> SyncPushData {
        try await post("sync/v1/push", body: SyncPushRequest(ops: ops), accessToken: accessToken)
    }

    /// 每日 JSON 全量导出（契约 §2：GET /export/v1/daily，需鉴权，可选 ?date=YYYY-MM-DD）。
    /// 带 query 参数不能走 appendingPathComponent 拼整串（? 会被百分号编码），
    /// 用 URLComponents 组装。
    func dailyExport(accessToken: String, date: String? = nil) async throws -> SyncDailyExportData {
        guard var comps = URLComponents(url: Self.baseURL.appendingPathComponent("export/v1/daily"),
                                         resolvingAgainstBaseURL: false) else {
            throw SyncCloudError(code: 50001, message: "云端地址无效")
        }
        if let date, !date.isEmpty {
            comps.queryItems = [URLQueryItem(name: "date", value: date)]
        }
        guard let url = comps.url else {
            throw SyncCloudError(code: 50001, message: "云端地址无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await send(req)
    }

    // MARK: - 通用请求（信封解包，非 code:0 抛 SyncCloudError）

    private func get<T: Decodable>(_ path: String, accessToken: String? = nil) async throws -> T {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        if let atk = accessToken {
            req.setValue("Bearer \(atk)", forHTTPHeaderField: "Authorization")
        }
        return try await send(req)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B,
                                                 accessToken: String? = nil) async throws -> T {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let atk = accessToken {
            req.setValue("Bearer \(atk)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try encoder.encode(body)
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw SyncCloudError(code: 50001, message: "云端响应无效")
        }
        guard http.statusCode == 200 else {
            // 网关层错误（429 限流等）：body 仍是契约信封，尝试解出错误码
            if let env = try? decoder.decode(SyncEnvelope<T>.self, from: data) {
                throw SyncCloudError(code: env.code, message: env.message ?? "")
            }
            throw SyncCloudError(code: 50001, message: "HTTP \(http.statusCode)")
        }
        let env: SyncEnvelope<T>
        do {
            env = try decoder.decode(SyncEnvelope<T>.self, from: data)
        } catch {
            throw SyncCloudError(code: 50001, message: "云端响应解析失败（可能超出 3 秒执行限制，请重试）")
        }
        guard env.code == 0, let d = env.data else {
            throw SyncCloudError(code: env.code, message: env.message ?? "")
        }
        return d
    }
}

/// logout 等仅返回 { logged_out: true } 类的端点 data 容器
struct SyncOkData: Decodable {
    let loggedOut: Bool?
}

struct SyncEmptyRequest: Encodable {}
