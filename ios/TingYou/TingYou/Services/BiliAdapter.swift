import Foundation

/// B站风控拦截错误（HTTP 412/403 或 body code -412/-352/-509）——
/// 与普通业务错误区分开：风控类按退避表重试，业务类（404/付费等）不重试
///（build 37 · abts playUrl：只有风控类错误值得重试）。
struct BiliRiskError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// B站视频音轨适配器（build 29 · 对齐 Android BiliAdapter.kt；build 37 · 播放链路对齐 abts）
///
/// build 37 技术路线：playurl 改走 WBI 签名接口 /x/player/wbi/playurl
/// （fnval=4048、qn=80、try_look=1、gaia_source=prefer-ua）——此前无签名的
/// /x/player/playurl + fnval=16 已被风控拒绝，是「能搜索、不能播」的直接原因；
/// 可播判定按 abts 口径：flac / dolby / dash.audio 任一 baseUrl 或 backupUrls
/// 非空；view 接口取视频标题/UP主/分P列表；请求头复刻桌面浏览器；
/// 风控应对：本地种 buvid3（大写 UUID + 5 位零填充随机数 + infoc）/ buvid4 +
/// gaia ExClimbWuzhi 激活（3064/39c8/3c43 载荷）；HTTP 412/403 或 body code
/// ∈ {-412,-352,-509} 时按 [1200,2600,5000]ms 阶梯退避并重种 b_nut 后重试；
/// 访客态最小请求间隔 450ms。
actor BiliAdapter {
    static let USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    static let REFERER = "https://www.bilibili.com"

    /// 412 阶梯退避表（毫秒）
    static let BACKOFF_MILLIS: [UInt64] = [1_200_000_000, 2_600_000_000, 5_000_000_000]
    /// 访客态最小请求间隔（纳秒）
    static let MIN_REQUEST_GAP_NS: UInt64 = 450_000_000
    /// 响应体大小上限（8MB）
    private static let MAX_BODY_BYTES: Int64 = 8 * 1024 * 1024
    /// gaia 预激活网关
    private static let GAIA_URL = "https://api.bilibili.com/x/internal/gaia-gateway/ExClimbWuzhi"
    /// buvid3 长度（UUID v4 36 位 + 5 位零填充随机数 + "infoc"，abts genBuvid3 口径）
    static let BUVID3_LENGTH = 46

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
    /// WBI 签名密钥缓存（密钥每日轮换，TTL 沿用搜索侧 BiliSearchApi.WBI_KEY_TTL_MS）
    private var cachedWbiKey: String?
    private var wbiKeyFetchedAt: UInt64 = 0
    /// build 44 · 反馈 3（B站 Cannot Open）：分P列表进程内缓存（bvid → pages）。
    /// 分P 结构（cid/page/part）对已发布视频不变，命中后切章零请求——每章播放
    /// 原先都要重拉 view（3 请求/章 + 预取放大），是风控 412 的主要消耗方。
    private var pageCache: [String: [BiliPage]] = [:]

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

    // MARK: - build 44 · 反馈 3（B站 Cannot Open）：分P获取改走 pagelist

    /// /x/player/pagelist 接口 URL 构造（纯函数，供单测断言）。
    static func buildPageListUrl(apiBase: String, bvid: String) -> String {
        "\(apiBase)/x/player/pagelist?bvid=\(bvid)"
    }

    /// 分P列表获取（abts pageList 同款接口）。build 44 沙箱取证（2026-10-27）：
    /// /x/web-interface/view 对匿名高频连续请求稳定 412（3 连 3 败），
    /// /x/player/pagelist 连续 3 次全部 200 零风控——播放链路的分P获取从 view
    /// 迁移到本接口，view 仅作为兜底保留。
    func pageList(bvid: String) async -> Result<[BiliPage], Error> {
        do {
            try await warmup()
            let json = try await requestJsonWithBackoff(url: Self.buildPageListUrl(apiBase: apiBase, bvid: bvid))
            return .success(try Self.parsePageList(json))
        } catch {
            return .failure(error)
        }
    }

    /// 播放链路分P获取复合入口：缓存命中（零请求）→ pagelist（轻接口零风控）→
    /// view 兜底（接口本身有 412 风险，仅在 pagelist 失败时使用）。结果写缓存。
    /// 分P 结构对已发布视频不变，缓存进程内有效（切章/重播/预取全部命中）。
    func playablePages(bvid: String) async -> Result<[BiliPage], Error> {
        if let cached = pageCache[bvid], !cached.isEmpty {
            return .success(cached)
        }
        let pagelist = await pageList(bvid: bvid)
        if case .success(let pages) = pagelist, !pages.isEmpty {
            pageCache[bvid] = pages
            return pagelist
        }
        // 兜底：pagelist 失败（如个别视频 pagelist 空返回）走 view（原路径）
        let info = await videoInfo(bvid: bvid)
        switch info {
        case .success(let v):
            if !v.pages.isEmpty {
                pageCache[bvid] = v.pages
            }
            return .success(v.pages)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// pagelist 响应解析（纯函数注入 json 供单测）：
    /// data[] 元素含 cid/page/part/duration，映射口径与 parseVideoInfo 的
    /// pages 分支一致（cid>0 过滤、part 缺省 P<n>）。
    static func parsePageList(_ json: [String: Any]) throws -> [BiliPage] {
        guard let arr = json["data"] as? [[String: Any]] else {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "B站分P列表缺少 data 字段"])
        }
        var pages: [BiliPage] = []
        for (i, p) in arr.enumerated() {
            let cid = (p["cid"] as? NSNumber)?.int64Value ?? -1
            guard cid > 0 else { continue }
            let part = (p["part"] as? String)?.trimmingCharacters(in: .whitespaces)
                ?? "P\(p["page"] as? Int ?? i + 1)"
            pages.append(BiliPage(cid: cid,
                                   page: p["page"] as? Int ?? i + 1,
                                   part: part))
        }
        guard !pages.isEmpty else {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "B站分P列表为空"])
        }
        return pages
    }

    // MARK: - DASH 音轨直链

    /// build 37 · 对齐 abts playUrl：WBI 签名接口 + 共 3 次尝试（1800ms × attempt
    /// 递增间隔）；仅风控类错误与「无可用音轨」重试，其余（404/付费等）立即失败。
    func audioStreamUrl(bvid: String, cid: Int64) async -> Result<String, Error> {
        do {
            try await warmup()
            var lastError: Error = URLError(.badServerResponse,
                                            userInfo: [NSLocalizedDescriptionKey: paidOrUnavailableMessage])
            for attempt in 0..<3 {
                if attempt > 0 {
                    try await Task.sleep(nanoseconds: 1_800_000_000 * UInt64(attempt))
                }
                do {
                    let key = try await wbiKey()
                    let wts = UInt64(Date().timeIntervalSince1970)
                    let url = Self.buildPlayUrl(apiBase: apiBase, bvid: bvid, cid: cid,
                                                wbiKey: key, wtsSeconds: wts)
                    let json = try await requestJsonWithBackoff(url: url)
                    let code = json["code"] as? Int ?? -1
                    if code != 0 {
                        let message = json["message"] as? String ?? ""
                        if Self.isRiskCode(code) {
                            lastError = BiliRiskError(message: biliApiError(code: code, message: message))
                            continue
                        }
                        throw URLError(.badServerResponse,
                                       userInfo: [NSLocalizedDescriptionKey: biliApiError(code: code, message: message)])
                    }
                    guard let stream = try? extractPlayableUrl(json) else {
                        // abts：无可用音轨同样视为可重试失败（避免上层静默拿到空地址）
                        lastError = URLError(.badServerResponse,
                                             userInfo: [NSLocalizedDescriptionKey: paidOrUnavailableMessage])
                        continue
                    }
                    return .success(stream)
                } catch {
                    if error is BiliRiskError {
                        lastError = error
                        continue
                    }
                    throw error
                }
            }
            return .failure(lastError)
        } catch {
            return .failure(error)
        }
    }

    /// 从 playurl 响应抽取可播直链：flac / dolby（含 dolby.audio[]）/ dash.audio[]
    /// 合并后按码率降序选最优（abts _hasPlayableUrl 的可播判定口径）。
    /// build 47：合并后过 codec 过滤——EC-3（Dolby Digital Plus，dolby.audio 轨
    /// 的编码）AVFoundation 不支持直接解（与真机 -12847「media format is not
    /// supported」同族），按 codecs 字段排除，绝不能喂给 AVPlayer。
    private func extractPlayableUrl(_ json: [String: Any]) throws -> String {
        guard let data = json["data"] as? [String: Any] else {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: paidOrUnavailableMessage])
        }
        var tracks: [[String: Any]] = []
        if let dash = data["dash"] as? [String: Any] {
            if let flac = dash["flac"] as? [String: Any] {
                tracks.append(flac)
            }
            if let dolby = dash["dolby"] as? [String: Any] {
                if let dolbyTracks = dolby["audio"] as? [[String: Any]] {
                    tracks.append(contentsOf: dolbyTracks)
                } else {
                    tracks.append(dolby)
                }
            }
            tracks.append(contentsOf: dash["audio"] as? [[String: Any]] ?? [])
        }
        // build 47 · codec 过滤：排除 EC-3（Dolby）轨——AVFoundation 不认 ec-3，
        // 选中即 -12847（b46 交付的观察项转正式修复）。全轨被滤掉时与无音轨
        // 同口径（paidOrUnavailableMessage），不静默选坏轨。
        tracks = tracks.filter { Self.hasPlayableCodec($0) }
        guard !tracks.isEmpty else {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: paidOrUnavailableMessage])
        }
        return try selectStreamUrl(tracks)
    }

    /// build 47：音轨 codec 可播判定——EC-3（Dolby Digital Plus，写法
    /// "ec-3"/"ec3"）AVFoundation 不支持直接解，排除；无 codecs 字段的轨
    ///（flac/dolby 顶层对象可能缺）不拦，交由既有选流逻辑处理。
    private static func hasPlayableCodec(_ track: [String: Any]) -> Bool {
        guard let codecs = (track["codecs"] as? String)?.lowercased() else { return true }
        if codecs.contains("ec-3") || codecs.contains("ec3") { return false }
        return true
    }

    /// WBI 签名密钥（nav 接口无需登录态即可取到 wbi_img；TTL 与搜索侧一致）
    private func wbiKey() async throws -> String {
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        if let key = cachedWbiKey, now - wbiKeyFetchedAt < BiliSearchApi.WBI_KEY_TTL_MS {
            return key
        }
        let json = try await requestJsonWithBackoff(url: "\(apiBase)/x/web-interface/nav")
        guard let data = json["data"] as? [String: Any],
              let wbi = data["wbi_img"] as? [String: Any],
              let img = wbi["img_url"] as? String, !img.isEmpty,
              let sub = wbi["sub_url"] as? String, !sub.isEmpty else {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "WBI 密钥获取失败"])
        }
        let key = BiliSearchApi.mixinKey(imgUrl: img, subUrl: sub)
        cachedWbiKey = key
        wbiKeyFetchedAt = DispatchTime.now().uptimeNanoseconds / 1_000_000
        return key
    }

    /// build 37 · WBI 签名 playurl URL 构造（abts 口径：8 个业务参数 + wts，
    /// 参数名排序后拼 query，w_rid = md5(query + mixinKey)——与搜索侧 buildSearchUrl 同一签名约定）。
    static func buildPlayUrl(apiBase: String, bvid: String, cid: Int64,
                             wbiKey: String, wtsSeconds: UInt64) -> String {
        let params: [(String, String)] = [
            ("bvid", bvid),
            ("cid", String(cid)),
            ("qn", "80"),
            ("fnval", "4048"),
            ("fnver", "0"),
            ("fourk", "1"),
            ("try_look", "1"),
            ("gaia_source", "prefer-ua"),
            ("wts", String(wtsSeconds)),
        ]
        let sorted = params.sorted { $0.0 < $1.0 }
        let query = sorted.map { "\($0.0)=\(BiliSearchApi.encodeValue($0.1))" }.joined(separator: "&")
        let wRid = BiliSearchApi.md5Hex(query + wbiKey)
        return "\(apiBase)/x/player/wbi/playurl?\(query)&w_rid=\(wRid)"
    }

    /// 风控响应码（abts：HTTP 412/403 与 body code -412/-352/-509 一视同仁）
    static func isRiskCode(_ code: Int) -> Bool {
        code == -412 || code == -352 || code == -509
    }

    private func selectStreamUrl(_ audio: [[String: Any]]) throws -> String {
        var best: String?
        var bestBandwidth: Int64 = -1
        for track in audio {
            // flac/dolby 对象可能缺 bandwidth 字段——按 0 处理保证首个可播直链可用
            //（dash.audio 正常都带 bandwidth，不影响「按码率降序选最优」的既有语义）
            let bw = track["bandwidth"] as? Int64 ?? 0
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
        // build 37：补 "backupUrls" 复数键——flac/dolby 对象偶用该形态
        for key in ["backupUrl", "backup_url", "backupUrls"] {
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
                // abts _mitigateRisk：重种 b_nut（毫秒时间戳）抬高后续请求成功率
                mitigateRisk()
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
                if http.statusCode == 412 || http.statusCode == 403 {
                    throw BiliRiskError(message: "B站接口风控拦截（HTTP \(http.statusCode)）")
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
                // build 37：body 风控码（-412/-352/-509）与 HTTP 412/403 一视同仁——
                // 抛 BiliRiskError 让本层退避表接管重试（abts _isRiskResponse 口径）
                if let code = obj["code"] as? Int, Self.isRiskCode(code) {
                    throw BiliRiskError(message: biliApiError(code: code,
                                                               message: obj["message"] as? String ?? ""))
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
        // abts：本地直接种入 buvid3/buvid4——缺设备标识会被判异常请求直接 412
        if force || cookieValue(name: "buvid3", forHost: "bilibili.com") == nil {
            let buvid3 = Self.genBuvid3()
            if let cookie = makeCookie(name: "buvid3", value: buvid3, domain: ".bilibili.com") {
                cookieStorage.setCookie(cookie)
            }
        }
        if force || cookieValue(name: "buvid4", forHost: "bilibili.com") == nil {
            if let cookie = makeCookie(name: "buvid4", value: Self.genBuvid3(), domain: ".bilibili.com") {
                cookieStorage.setCookie(cookie)
            }
        }
        // gaia 激活（build 37 · abts ExClimbWuzhi 3064/39c8/3c43 载荷，
        // 请求体为 {"payload": "<payload json 字符串>"}，payload 值整体是一段 JSON 文本）
        do {
            let png = Self.genPngBase64()
            let payload = Self.buildGaiaPayload(pngBase64: png)
            guard let url = URL(string: gaiaUrl) else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["payload": payload])
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

    /// 风控补救（abts _mitigateRisk 的 b_nut 部分）：重种 b_nut（毫秒时间戳）。
    /// buvid3/buvid4 由调用侧 forceNewIdentity → ensureBuvidActivated(force:) 重种。
    private func mitigateRisk() {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        if let cookie = makeCookie(name: "b_nut", value: String(nowMs), domain: ".bilibili.com") {
            cookieStorage.setCookie(cookie)
        }
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

    /// buvid3 生成（build 37 · abts genBuvid3：大写 UUID v4 + 5 位零填充随机数 + "infoc"）
    static func genBuvid3(random: inout UInt64) -> String {
        func nextMod(_ modulus: UInt64) -> UInt64 {
            random = random &* 6364136223846793005 &+ 1
            return (random >> 33) % modulus
        }
        func hex(_ n: Int) -> String {
            (0..<n).map { _ in String(format: "%x", Int(nextMod(16))) }.joined()
        }
        // UUID v4：version 固定 4，variant 取 8..b 一位十六进制
        let variant = String(format: "%x", Int(8 + nextMod(4)))
        let uuid = "\(hex(8))-\(hex(4))-4\(hex(3))-\(variant)\(hex(3))-\(hex(12))"
        let suffix = String(format: "%05d", Int(nextMod(100_000)))
        return uuid.uppercased() + suffix + "infoc"
    }

    /// 确定性 buvid3 生成（单测用）
    static func genBuvid3(seed: UInt64) -> String {
        var rng = seed
        return genBuvid3(random: &rng)
    }

    /// 便捷入口：取系统随机种子生成 buvid3（运行时用）
    static func genBuvid3() -> String {
        genBuvid3(seed: UInt64.random(in: UInt64.min...UInt64.max))
    }

    /// gaia 激活 PNG（abts bili_client.dart：32 随机字节 + 0,0,0,0,73,69,78,68 + 4 随机字节 → base64）
    static func genPngBase64(random: inout UInt64) -> String {
        var bytes: [UInt8] = []
        for _ in 0..<32 {
            random = random &* 6364136223846793005 &+ 1
            bytes.append(UInt8((random >> 33) % 256))
        }
        bytes.append(contentsOf: [0, 0, 0, 0, 73, 69, 78, 68])
        for _ in 0..<4 {
            random = random &* 6364136223846793005 &+ 1
            bytes.append(UInt8((random >> 33) % 256))
        }
        return Data(bytes).base64EncodedString()
    }

    /// 运行时入口：系统随机种子生成 gaia PNG
    static func genPngBase64() -> String {
        var rng = UInt64.random(in: UInt64.min...UInt64.max)
        return genPngBase64(random: &rng)
    }

    /// gaia 激活载荷（build 37 · abts 3064/39c8/3c43 三键 + PNG 尾 50 字符）
    static func buildGaiaPayload(pngBase64: String) -> String {
        let tail = String(pngBase64.suffix(50))
        return "{\"3064\":1,\"39c8\":\"333.1387.fp.risk\",\"3c43\":{\"adca\":\"Linux\",\"bfe9\":\"\(tail)\"}}"
    }
}
