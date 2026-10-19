import Foundation

/// 付费章节异常（安卓 PaidChapterException 对等）：列表打标 + 拦截，不绕过（ADR-008）。
struct PaidChapterException: Error {
    let src: String
    let albumId: String
    let chapter: String
}

/// ting15 / ting08 共用适配器（安卓 MsrcAdapter.kt 的 Swift 移植，设计文档第三章）：
/// - 搜索：GET 优先（两站实测都支持），GET 失败或空结果且该源支持 POST 时回退 POST；
/// - 详情：GET {base}{detailPath} 宽容 HTML 解析（近缓存避免重复抓取）；
/// - 播放：两步 token（播放页刮 _c/_p meta → POST api-getneoplay）；
///   - status -1 = 付费章：打标进 paidChapters 并拦截；
///   - status -2 = 频控：+3s / +8s 各退避重试一次，仍 -2 透传错误；
///   - 返回前音频直链过源白名单自检。
final class MsrcAdapter: Sendable {

    private let apiClient: APIClient
    private let paidChapters: PaidChapterRegistry
    private let backoffDelaysMs: [Int64]

    init(apiClient: APIClient,
         paidChapters: PaidChapterRegistry = PaidChapterRegistry(),
         backoffDelaysMs: [Int64] = [3_000, 8_000]) {
        self.apiClient = apiClient
        self.paidChapters = paidChapters
        self.backoffDelaysMs = backoffDelaysMs
    }

    private func cfgOf(_ src: String) throws -> SourceRegistry.MsrcSourceConfig {
        guard let cfg = SourceRegistry.configOf(src: src) else {
            throw URLError(.unsupportedURL)
        }
        return cfg
    }

    // MARK: - 搜索（GET 优先，POST 回退）

    func search(src: String, keyword: String) async throws -> [MsrcHtml.MsrcSearchItem] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if kw.isEmpty { return [] }
        let cfg = try cfgOf(src)
        // GET 优先（v1.0.6 鲁棒性：两站均支持 GET，统一 GET 优先降低被限流面）
        var getItems: [MsrcHtml.MsrcSearchItem] = []
        do {
            let url = cfg.siteBase + "/?s=ting-search-wd-" + MsrcHtml.encodeUriComponent(kw) + ".html"
            getItems = MsrcHtml.parseSearch(cfg: cfg, html: try await apiClient.fetchHTML(url, headers: ["Referer": cfg.referer]))
        } catch {
            if !cfg.searchPOST { throw error }
            getItems = [] // GET 失败 → POST 回退
        }
        if !getItems.isEmpty || !cfg.searchPOST { return getItems }
        // GET 无结果且该源支持 POST → 回退（ting08 差异链路）
        let html = try await apiClient.postFormForString(
            cfg.siteBase + "/?s=ting-search",
            fields: ["wd": kw],
            headers: ["Referer": cfg.referer, "Origin": cfg.siteBase])
        return MsrcHtml.parseSearch(cfg: cfg, html: html)
    }

    // MARK: - 详情（专辑 + 章节一次抓取，宽容解析）

    func detail(src: String, detailPath: String) async throws -> MsrcHtml.MsrcDetail {
        guard !detailPath.isEmpty, detailPath.hasPrefix("/"), !detailPath.contains("..") else {
            throw URLError(.badURL)
        }
        let cfg = try cfgOf(src)
        return try await DetailCache.shared.get(key: "\(src)\(detailPath)") {
            try await self.apiClient.fetchHTML(cfg.siteBase + detailPath, headers: ["Referer": cfg.referer])
        }
    }

    // MARK: - 播放（两步 token）

    /// markPaid=false 时探测到付费（-1）不打标（只抛 PaidChapterException），供预加载静默跳过；
    /// 正常播放路径默认 true（真实播放尝试到 -1 才打标）。
    func getPlayUrl(src: String, bookId: Int64, page: Int, markPaid: Bool = true) async throws -> String {
        let cfg = try cfgOf(src)
        guard bookId > 0, page >= 1 else { throw URLError(.badURL) }
        let bookIdStr = String(bookId)
        let paidKey = "\(src):\(bookIdStr):\(page)"

        // 请求层付费拦截（先查本地打标，避免对已知付费章反复发请求）
        if paidChapters.contains(paidKey) {
            throw PaidChapterException(src: src, albumId: bookIdStr, chapter: String(page))
        }

        // 第一步：播放页刮 token
        let playUrl = cfg.siteBase + "/?s=ting-play-id-\(bookIdStr)-sid-0-pid-\(page).html"
        let playHtml = try await apiClient.fetchHTML(playUrl, headers: ["Referer": cfg.referer])
        guard let meta = MsrcHtml.parsePlayPage(playHtml) else {
            throw URLError(.cannotParseResponse) // 播放页缺少 token（站点页面结构变化或临时异常）
        }

        // 第二步：POST api-getneoplay（-2 频控按退避序列重试）
        func call() async throws -> MsrcHtml.MsrcPlayResult {
            var headers = ["Referer": cfg.referer, "xt": meta.token]
            if cfg.extraLHeader { headers["l"] = "1" } // ting08 差异点
            let body = try await apiClient.postFormForString(
                cfg.siteBase + "/?s=api-getneoplay",
                fields: ["bookId": bookIdStr, "isPay": meta.isPay, "page": String(page)],
                headers: headers)
            return MsrcHtml.parsePlayResponse(body)
        }

        var res = (try? await call()) ?? MsrcHtml.MsrcPlayResult.error("音频接口请求失败")
        if res.status == -2 {
            for waitMs in backoffDelaysMs {
                try await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
                res = (try? await call()) ?? MsrcHtml.MsrcPlayResult.error("音频接口请求失败")
                if res.status != -2 { break }
            }
        }

        switch res.status {
        case 1:
            guard let raw = res.url, !raw.isEmpty else {
                throw URLError(.badServerResponse)
            }
            guard let httpUrl = URL(string: raw), let host = httpUrl.host() else {
                throw URLError(.badURL) // 播放地址不合法
            }
            // 出站白名单自检（设计红线：返回的直链 host 必须在该源白名单内）
            guard SourceRegistry.audioHostAllowed(cfg: cfg, host: host) else {
                throw URLError(.badURL) // 音频地址不在源白名单内，已拦截
            }
            return raw
        case -1:
            // 付费章：列表打标 + 拦截，不绕过
            if markPaid { paidChapters.mark(paidKey) }
            throw PaidChapterException(src: src, albumId: bookIdStr, chapter: String(page))
        case -2:
            throw URLError(.timedOut) // 访问过快（站点频控），请稍后再试
        default:
            throw URLError(.badServerResponse)
        }
    }
}

/// 跨源共享的付费章打标集（安卓 ConcurrentHashMap.newKeySet 对等；NSLock 保护）
final class PaidChapterRegistry: @unchecked Sendable {
    private var keys = Set<String>()
    private let lock = NSLock()
    init() {}
    static let shared = PaidChapterRegistry()
    func contains(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keys.contains(key)
    }
    func mark(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        keys.insert(key)
    }
}

/// 详情近缓存（LRU 8 条，跨源键隔离）
final class DetailCache: @unchecked Sendable {
    static let shared = DetailCache()
    private var cache: [String: (date: Date, value: MsrcHtml.MsrcDetail)] = [:]
    private let lock = NSLock()
    private let maxEntries = 8
    private let ttl: TimeInterval = 300

    func get(key: String, fetch: () async throws -> String) async throws -> MsrcHtml.MsrcDetail {
        lock.lock()
        if let hit = cache[key], Date().timeIntervalSince(hit.date) < ttl {
            lock.unlock()
            return hit.value
        }
        lock.unlock()
        let html = try await fetch()
        let parsed = MsrcHtml.parseDetail(html)
        lock.lock()
        cache[key] = (Date(), parsed)
        if cache.count > maxEntries { cache.removeValue(forKey: cache.keys.first!) }
        lock.unlock()
        return parsed
    }
}
