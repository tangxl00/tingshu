import Foundation

/// B站视频音轨适配器（build 29 · 对齐 Android BiliAdapter.kt）
///
/// 技术路线：playurl fnval=16（DASH 音轨分离）→ dash.audio[] 按码率降序取最高；
/// view 接口取视频标题/UP主/分P列表；请求头复刻桌面浏览器；
/// 风控应对：调 API 前先访问首页获取初始 cookie（buvid3），进程内 CookieStorage 保持；
/// 412 阶梯退避；访客态最小请求间隔 450ms。
actor BiliAdapter {
    static let USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let REFERER = "https://www.bilibili.com"

    /// 412 阶梯退避表（毫秒）
    static let BACKOFF_MILLIS: [UInt64] = [1_200_000_000, 2_600_000_000, 5_000_000_000]
    /// 访客态最小请求间隔（纳秒）
    static let MIN_REQUEST_GAP_NS: UInt64 = 450_000_000
    /// 响应体大小上限（8MB）
    private static let MAX_BODY_BYTES: Int64 = 8 * 1024 * 1024
    /// 访客态 mid
    private static let MID_ANONYMOUS = 1
    /// gaia 预激活网关
    private static let GAIA_URL = "https://api.bilibili.com/x/internal/gaia-gateway/ExClimbWuzhi"
    /// buvid3 字符集
    private static let BUVID3_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    /// buvid3 长度
    private static let BUVID3_LENGTH = 32

    private let apiBase: String
    private let homeBase: String
    private let gaiaUrl: String

    /// 独立 URLSession（B站请求不得复用 APIClient 默认 session，因默认 UA 无 Referer 会被 CDN 403）
    private let session: URLSession
    /// 进程内 CookieStorage
    private let cookieStorage = HTTPCookieStorage()

    /// buvid 预激活状态
    private var buvidActivated = false
    /// cookie 预热状态
    private var cookiesReady = false
    /// 节流锁（actor 隔离已提供串行化，但 lastRequestAt 需原子更新）
    private var lastRequestAt: UInt64 = 0

    init(apiBase: String = "https://api.bilibili.com",
         homeBase: String = "https://www.bilibili.com",
         gaiaUrl: String = BiliAdapter.GAIA_URL) {
        self.apiBase = apiBase
        self.homeBase = homeBase
        self.gaiaUrl = gaiaUrl

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = cookieStorage
        config.httpAdditionalHeaders = [
            "User-Agent": BiliAdapter.USER_AGENT,
            "Referer": BiliAdapter.REFERER,
            "Origin": BiliAdapter.REFERER,
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - 视频信息

    struct BiliVideoInfo {
        let bvid: String
        let title: String
        let upName: String
        let pages: [BiliPage]
        let paid: Bool
    }

    struct BiliPage: Hashable, Sendable {
        let cid: Int64
        let page: Int
        let part: String
    }

    func videoInfo(bvid: String) async -> Result<BiliVideoInfo, Error> {
        await fetchInfo(url: "\(apiBase)/x/web-interface/view?bvid=\(bvid)")
    }

    func videoInfoByAid(aid: Int64) async -> Result<BiliVideoInfo, Error> {
        await fetchInfo(url: "\(apiBase)/x/web-interface/view?aid=\(aid)")
    }

    private func fetchInfo(url: String) async -> Result<BiliVideoInfo, Error> {
        do {
            try await warmup()
            let json = try await requestJsonWithBackoff(url: url)
            return .success(try parseVideoInfo(json))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - DASH 音轨直链

    func audioStreamUrl(bvid: String, cid: Int64) async -> Result<String, Error> {
        do {
            try await warmup()
            let json = try await requestJsonWithBackoff(url:
                "\(apiBase)/x/player/playurl?bvid=\(bvid)&cid=\(cid)&fnval=16&fnver=0&fourk=1")
            let code = json["code"] as? Int ?? -1
            if code != 0 {
                throw URLError(.badServerResponse,
                               userInfo: [NSLocalizedDescriptionKey: biliApiError(code: code, message: "")])
            }
            guard let data = json["data"] as? [String: Any],
                  let dash = data["dash"] as? [String: Any],
                  let audio = dash["audio"] as? [[String: Any]] else {
                throw URLError(.badServerResponse,
                               userInfo: [NSLocalizedDescriptionKey: paidOrUnavailableMessage])
            }
            return .success(try selectStreamUrl(audio))
        } catch {
            return .failure(error)
        }
    }

    private func selectStreamUrl(_ audio: [[String: Any]]) throws -> String {
        var best: String?
        var bestBandwidth: Int64 = -1
        for track in audio {
            let bw = track["bandwidth"] as? Int64 ?? -1
            if bw <= bestBandwidth { continue }
            let candidates = [
                track["baseUrl"] as? String,
                track["base_url"] as? String,
            ].compactMap { $0 } + backupUrls(from: track)
            if let url = candidates.first(where: { isAllowedStreamUrl($0) }) {
                bestBandwidth = bw
                best = url
            }
        }
        guard let result = best else {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey:
                            "B站音轨直链域名均不在白名单或无可用音轨，拒绝播放（App 不提供绕过）"])
        }
        return result
    }

    private func backupUrls(from track: [String: Any]) -> [String] {
        var result: [String] = []
        for key in ["backupUrl", "backup_url"] {
            if let arr = track[key] as? [String] {
                result.append(contentsOf: arr)
            }
        }
        return result
    }

    private func isAllowedStreamUrl(_ url: String) -> Bool {
        guard url.hasPrefix("https://"),
              let host = URL(string: url)?.host else { return false }
        return BiliSource.hostAllowed(host)
    }

    // MARK: - b23.tv 短链解析

    func resolveShortLink(url: String) async -> BiliInputParser.Parsed? {
        guard let urlObj = URL(string: url) else { return nil }
        var req = URLRequest(url: urlObj)
        req.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse,
               let final = http.url?.absoluteString {
                return BiliInputParser.parse(final)
            }
        } catch {
            // 静默失败，返回 nil
        }
        return nil
    }

    // MARK: - 通用 GET JSON（带 412 退避）

    func getJson(url: String) async throws -> [String: Any] {
        try await requestJsonWithBackoff(url: url)
    }

    private func requestJsonWithBackoff(url: String) async throws -> [String: Any] {
        var lastError: Error?
        var forceNewIdentity = false
        for attempt in 0...Self.BACKOFF_MILLIS.count {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: Self.BACKOFF_MILLIS[attempt - 1])
                cookiesReady = false
                forceNewIdentity = true
            }
            try await throttle()
            try await ensureBuvidActivated(force: forceNewIdentity)
            do {
                guard let urlObj = URL(string: url) else {
                    throw URLError(.badURL)
                }
                var req = URLRequest(url: urlObj)
                req.setValue(BiliAdapter.USER_AGENT, forHTTPHeaderField: "User-Agent")
                req.setValue(BiliAdapter.REFERER, forHTTPHeaderField: "Referer")
                req.setValue(BiliAdapter.REFERER, forHTTPHeaderField: "Origin")
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if http.statusCode == 412 {
                    throw URLError(.badServerResponse,
                                   userInfo: [NSLocalizedDescriptionKey: "B站接口风控拦截（HTTP 412）"])
                }
                guard http.statusCode == 200 else {
                    throw URLError(.badServerResponse,
                                   userInfo: [NSLocalizedDescriptionKey: "B站接口请求失败：HTTP \(http.statusCode)"])
                }
                // 流式读取 + 8MB 上限（已由 URLSession 控制，此处做二次校验）
                guard data.count <= Self.MAX_BODY_BYTES else {
                    throw URLError(.badServerResponse,
                                   userInfo: [NSLocalizedDescriptionKey: "响应超过 8MB 上限: \(url)"])
                }
                guard !data.isEmpty else {
                    throw URLError(.badServerResponse,
                                   userInfo: [NSLocalizedDescriptionKey: "B站接口响应为空"])
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw URLError(.badServerResponse,
                                   userInfo: [NSLocalizedDescriptionKey: "B站接口响应异常（非 JSON）"])
                }
                return obj
            } catch {
                lastError = error
                if attempt == Self.BACKOFF_MILLIS.count { break }
            }
        }
        throw lastError ?? URLError(.badServerResponse)
    }

    // MARK: - cookie 预热与 buvid 预激活

    func warmup() async throws {
        ensureCookies()
        try await ensureBuvidActivated()
    }

    private func ensureCookies() {
        guard !cookiesReady else { return }
        guard let url = URL(string: homeBase) else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: url) { _, _, _ in
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        cookiesReady = true
    }

    private func ensureBuvidActivated(force: Bool = false) async throws {
        if buvidActivated && !force { return }
        try await throttle()
        let existing = cookieValue(name: "buvid3", forHost: "bilibili.com")
        let buvid3: String
        if force || existing == nil {
            buvid3 = Self.genBuvid3()
            if let cookie = makeCookie(name: "buvid3", value: buvid3, domain: ".bilibili.com") {
                cookieStorage.setCookie(cookie)
            }
        } else {
            buvid3 = existing!
        }
        // gaia 激活
        do {
            let payload = Self.buildGaiaPayload(mid: Self.MID_ANONYMOUS, buvid3: buvid3, buvid4: "")
            guard let url = URL(string: gaiaUrl) else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = payload.data(using: .utf8)
            let (data, _) = try await session.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["code"] as? Int, code == 0,
               let dataObj = json["data"] as? [String: Any],
               let confirmed = dataObj["buvid"] as? String, !confirmed.isEmpty {
                if let cookie = makeCookie(name: "buvid3", value: confirmed, domain: ".bilibili.com") {
                    cookieStorage.setCookie(cookie)
                }
            }
        } catch {
            // 预激活失败不抛错，由请求层如实上报
        }
        buvidActivated = true
    }

    // MARK: - 节流

    private func throttle() async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let wait = (lastRequestAt + Self.MIN_REQUEST_GAP_NS > now)
            ? lastRequestAt + Self.MIN_REQUEST_GAP_NS - now
            : 0
        if wait > 0 {
            try await Task.sleep(nanoseconds: wait)
        }
        lastRequestAt = DispatchTime.now().uptimeNanoseconds
    }

    // MARK: - 解析

    private func parseVideoInfo(_ json: [String: Any]) throws -> BiliVideoInfo {
        let code = json["code"] as? Int ?? -1
        if code != 0 {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: biliApiError(code: code, message: "")])
        }
        guard let data = json["data"] as? [String: Any] else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "B站视频信息缺少 data 字段"])
        }
        let bvid = data["bvid"] as? String ?? ""
        guard !bvid.isEmpty else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "B站视频信息缺少 bvid 字段"])
        }
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? bvid
        let upName = (data["owner"] as? [String: Any])?["name"] as? String ?? ""
        var pages: [BiliPage] = []
        if let arr = data["pages"] as? [[String: Any]], !arr.isEmpty {
            for (i, p) in arr.enumerated() {
                let cid = p["cid"] as? Int64 ?? -1
                guard cid > 0 else { continue }
                let part = (p["part"] as? String)?.trimmingCharacters(in: .whitespaces)
                    ?? "P\(p["page"] as? Int ?? i + 1)"
                pages.append(BiliPage(cid: cid,
                                       page: p["page"] as? Int ?? i + 1,
                                       part: part))
            }
        } else {
            let cid = data["cid"] as? Int64 ?? -1
            guard cid > 0 else {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "B站视频缺少分P信息"])
            }
            pages.append(BiliPage(cid: cid, page: 1, part: title))
        }
        guard !pages.isEmpty else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "B站视频缺少可播放分P"])
        }
        let rights = data["rights"] as? [String: Any]
        let paid = rights != nil && (
            (rights?["pay"] as? Int ?? 0) == 1 ||
            (rights?["is_upower_exclusive"] as? Int ?? 0) == 1 ||
            (rights?["movie"] as? Int ?? 0) == 1
        )
        return BiliVideoInfo(bvid: bvid, title: title, upName: upName, pages: pages, paid: paid)
    }

    // MARK: - 工具

    private func cookieValue(name: String, forHost host: String) -> String? {
        guard let url = URL(string: "https://\(host)/") else { return nil }
        return cookieStorage.cookies(for: url)?.first { $0.name == name }?.value
    }

    private func makeCookie(name: String, value: String, domain: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
        ])
    }

    private var paidOrUnavailableMessage: String {
        "未获取到可播放音轨：该视频可能为付费/大会员/充电专属内容（未登录无法收听），或不包含音轨。App 不提供任何绕过。"
    }

    private func biliApiError(code: Int, message: String) -> String {
        let hint: String
        switch code {
        case -404: hint = "视频不存在（可能已下架或链接错误）"
        case 62002, 62012, 62004: hint = "该视频不可播放（可能为付费/会员专属或稿件不可见）"
        default: hint = "B站接口返回错误 code=\(code)\(message.isEmpty ? "" : "：\(message)")"
        }
        return "\(hint)。App 不提供绕过。"
    }

    // MARK: - 纯函数工具（单测可断言）

    /// buvid3 生成
    static func genBuvid3(random: inout UInt64) -> String {
        var result = ""
        for _ in 0..<BUVID3_LENGTH {
            random = random &* 6364136223846793005 &+ 1
            let idx = Int((random >> 33) % UInt64(BUVID3_ALPHABET.count))
            result.append(BUVID3_ALPHABET[BUVID3_ALPHABET.index(BUVID3_ALPHABET.startIndex, offsetBy: idx)])
        }
        return result
    }

    /// 确定性 buvid3 生成（单测用）
    static func genBuvid3(seed: UInt64) -> String {
        var rng = seed
        return genBuvid3(random: &rng)
    }

    /// gaia 激活载荷
    static func buildGaiaPayload(mid: Int, buvid3: String, buvid4: String) -> String {
        "{\"mid\":\(mid),\"buvid3\":\"\(buvid3)\",\"buvid4\":\"\(buvid4)\"}"
    }
}
