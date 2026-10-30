import Foundation

/// build 50 · 任务 2：易听书（yitingshu）适配器。
///
/// 站点形态（stui 模板站，与 PC 端 server.js 的 yts* 解析器逐条对齐）：
/// - 详情：GET /tingshu/{id}.html —— `<h1 class="title">` 书名、
///   `stui-content__thumb` 段内 `data-original` 封面、`/play/{bookId}-{sid}-{idx0}.html`
///   章节链接（只收本书 bookId）。
/// - 分类：GET /yi/{catId}-{page}.html —— `<a class="stui-vodlist__thumb lazyload"
///   href="/tingshu/{id}.html" ... title="..." data-original="...">`，每页 30 条，
///   分页信息在 `<span class="num">当前/总页</span>`。
/// - 播放：GET /play/{bookId}-0-{idx0}.html —— 页面内联 `var now="<直链>"`（单步）。
///   PC 端实测全站直链落在 aod.cos.tx.xmcdn.com，无需 Referer/UA。
/// - 搜索：站点 `search.php` 全路由被 vdimgck「系统安全验证」gate 拦截（PC 端实测），
///   因此搜索一律走本地标题索引（Resources/yts_index.txt，16,671 条，与 PC 同源），
///   live 搜索仅作为「索引未命中时的一次尝试」，命中 gate 即判定为不可用、回落索引。
///
/// 反爬边界（与项目其余音源同口径）：不做任何验证码绕过。命中 gate 只做降级，不重试。
struct YitingshuParsedDetail: Sendable, Equatable {
    let title: String
    let cover: String?
    let intro: String?
    let author: String?
    let chapters: [MsrcHtml.MsrcChapter]

    var chapterCount: Int { chapters.count }
}

enum YitingshuHtml {

    // MARK: - 正则（与 PC server.js 的 RE_YTS_* 同构）

    /// 列表项：`<a class="stui-vodlist__thumb lazyload" href="/tingshu/{id}.html" ... title="..." ... data-original="...">`
    static let reItem = try! NSRegularExpression(
        pattern: #"<a class="stui-vodlist__thumb lazyload" href="/tingshu/(\d+)\.html"[^>]*title="([^"]*)"[^>]*data-original="([^"]*)""#)

    /// 详情书名：`<h1 class="title">...</h1>`
    static let reH1 = try! NSRegularExpression(
        pattern: #"<h1 class="title">([\s\S]*?)</h1>"#)

    /// 详情封面：`stui-content__thumb` 段内的 data-original
    static let reCover = try! NSRegularExpression(
        pattern: #"class="stui-content__thumb"[\s\S]*?data-original="([^"]+)""#)

    /// 章节链接：`href="/play/{bookId}-{sid}-{idx0}.html" ...>标题</a>`
    static let rePlayLink = try! NSRegularExpression(
        pattern: #"href="/play/(\d+)-(\d+)-(\d+)\.html"[^>]*>([\s\S]*?)</a>"#)

    /// 播放页内联直链：`var now="https://..."`
    static let reNow = try! NSRegularExpression(
        pattern: #"var\s+now\s*=\s*"([^"]+)""#)

    /// 简介：PC 端 `id="desc"` 优先、退到 `class="col-pd"`
    static let reDescId = try! NSRegularExpression(
        pattern: #"id="desc"[\s\S]*?<p>([\s\S]*?)</p>"#)
    static let reDescClass = try! NSRegularExpression(
        pattern: #"class="col-pd"[^>]*>([\s\S]*?)</div>"#)

    /// 分类分页：`<span class="num">1/94</span>`
    static let reCatPages = try! NSRegularExpression(
        pattern: #"<span class="num">\s*(\d+)\s*/\s*(\d+)\s*</span>"#)

    private static let reTag = try! NSRegularExpression(pattern: #"<[^>]*>"#)

    // MARK: - gate 判定

    /// 命中即站点返回了「系统安全验证」拦截页（HTTP 200 但只有 3KB 验证码页）。
    /// 与 PC 端 ytsIsCaptchaGate 逐字一致：vdimgck 或「系统安全验证」。
    static func isCaptchaGate(_ html: String) -> Bool {
        html.contains("vdimgck") || html.contains("系统安全验证")
    }

    // MARK: - 转义

    /// PC 端 ytsUnescape：`&amp;amp;` → `&amp;` → `&` → `&quot;` → `&#39;`，顺序不可换。
    static func unescape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&amp;amp;", with: "&amp;")
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&#39;", with: "'")
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 封面补全：站点多数给 `//...` 协议相对或完整 https；`@` 前缀是索引文件里的省略写法。
    static func absCover(_ raw: String) -> String? {
        let s = unescape(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("@") { return "https://imagev2.xmcdn.com/" + s.dropFirst() }
        if s.hasPrefix("//") { return "https:" + s }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        if s.hasPrefix("/") { return "https://www.yitingshu.com" + s }
        return "https://www.yitingshu.com/" + s
    }

    private static func stripTags(_ s: String) -> String {
        let r = NSRange(s.startIndex..<s.endIndex, in: s)
        let out = reTag.stringByReplacingMatches(in: s, range: r, withTemplate: " ")
        return unescape(out)
    }

    private static func firstGroup(_ re: NSRegularExpression, _ s: String, _ group: Int = 1) -> String? {
        let r = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, range: r), group < m.numberOfRanges,
              let rr = Range(m.range(at: group), in: s) else { return nil }
        return String(s[rr])
    }

    // MARK: - 列表解析（分类页 / 搜索回退）

    /// 解析 `stui-vodlist` 列表项 → MsrcSearchItem（detailPath = 书 id）。
    static func parseList(_ html: String) -> [MsrcHtml.MsrcSearchItem] {
        // 只解析列表区块，避免把页头推荐位混进来（PC 端同样先切 <ul class="stui-vodlist clearfix">）
        let seg = sectionBetween(html,
                                 start: #"<ul class="stui-vodlist clearfix">"#,
                                 end: #"</ul>"#)
        let scope = seg.isEmpty ? html : seg
        let r = NSRange(scope.startIndex..<scope.endIndex, in: scope)
        var items: [MsrcHtml.MsrcSearchItem] = []
        var seen = Set<String>()
        reItem.enumerateMatches(in: scope, range: r) { m, _, _ in
            guard let m else { return }
            guard let idR = Range(m.range(at: 1), in: scope),
                  let tR = Range(m.range(at: 2), in: scope),
                  let cR = Range(m.range(at: 3), in: scope) else { return }
            let bookId = String(scope[idR])
            let title = unescape(String(scope[tR]))
            guard !bookId.isEmpty, !title.isEmpty, !seen.contains(bookId) else { return }
            seen.insert(bookId)
            items.append(MsrcHtml.MsrcSearchItem(
                title: title,
                author: nil,
                teller: nil,
                cover: absCover(String(scope[cR])),
                detailPath: bookId,
                bookId: bookId))
        }
        return items
    }

    /// 分类页总页数（`<span class="num">1/94</span>` 的分母）。取不到返回 nil。
    static func pageCount(_ html: String) -> Int? {
        guard let raw = firstGroup(reCatPages, html, 2) else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    /// 分类页当前页（分子）。
    static func currentPage(_ html: String) -> Int? {
        guard let raw = firstGroup(reCatPages, html, 1) else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - 详情解析

    static func parseDetail(_ html: String) -> YitingshuParsedDetail? {
        guard !isCaptchaGate(html) else { return nil }
        let rawTitle = firstGroup(reH1, html) ?? ""
        let title = stripTags(rawTitle)
        guard !title.isEmpty else { return nil }

        let cover = firstGroup(reCover, html).flatMap { absCover($0) }

        // 简介：id="desc" 优先，退 col-pd；PC 端截 600 字
        var intro: String? = nil
        if let d = firstGroup(reDescId, html) ?? firstGroup(reDescClass, html) {
            let clean = stripTags(d)
            if !clean.isEmpty {
                intro = clean.count > 600 ? String(clean.prefix(600)) : clean
            }
        }

        // 章节：/play/{bookId}-{sid}-{idx0}.html，只收本书 bookId，page = idx0 + 1
        let bookIdOfPage: String? = firstGroup(rePlayLink, html, 1)
        let r = NSRange(html.startIndex..<html.endIndex, in: html)
        var chapters: [MsrcHtml.MsrcChapter] = []
        var seen = Set<Int>()
        rePlayLink.enumerateMatches(in: html, range: r) { m, _, _ in
            guard let m else { return }
            guard let bR = Range(m.range(at: 1), in: html),
                  let iR = Range(m.range(at: 3), in: html),
                  let tR = Range(m.range(at: 4), in: html) else { return }
            let bid = String(html[bR])
            // 只收本书：PC 端同口径（详情页可能夹带推荐位的其它书播放链接）
            if let bound = bookIdOfPage, bid != bound { return }
            guard let idx0 = Int(String(html[iR])) else { return }
            let page = idx0 + 1
            guard !seen.contains(page) else { return }
            seen.insert(page)
            chapters.append(MsrcHtml.MsrcChapter(page: page, title: stripTags(String(html[tR]))))
        }
        // 按 page 升序（站点已是正序，这里防御性排序）
        chapters.sort { $0.page < $1.page }

        return YitingshuParsedDetail(title: title, cover: cover, intro: intro,
                                     author: nil, chapters: chapters)
    }

    // MARK: - 播放页直链

    /// 播放页内联 `var now="..."` → 直链（仅收 https + 音频白名单主机）。
    static func parsePlayUrl(_ html: String, cfg: SourceRegistry.MsrcSourceConfig) -> String? {
        guard !isCaptchaGate(html) else { return nil }
        guard let raw = firstGroup(reNow, html) else { return nil }
        let url = unescape(raw).replacingOccurrences(of: "\\/", with: "/")
        guard url.hasPrefix("https://"), let u = URL(string: url), let host = u.host else { return nil }
        guard SourceRegistry.audioHostAllowed(cfg: cfg, host: host) else { return nil }
        return url
    }

    // MARK: - sectionBetween

    static func sectionBetween(_ s: String, start: String, end: String) -> String {
        guard let a = s.range(of: start) else { return "" }
        guard let b = s.range(of: end, range: a.upperBound..<s.endIndex) else {
            return String(s[a.lowerBound...])
        }
        return String(s[a.upperBound..<b.lowerBound])
    }
}

// MARK: - 本地标题索引

/// 易听书本地标题索引（与 PC 端同源快照：16,671 条，`id|书名|封面` 每行一条，
/// 封面 `@` 前缀表示省去 `https://imagev2.xmcdn.com/`）。
///
/// 为什么必须有它：站点 `search.php` 全路由被验证码 gate 拦截（PC v1.1.8 实测），
/// 没有本地索引 iOS 端就完全搜不到易听书的书。索引是静态快照、不自动更新，
/// 新增书需随版本重建（与 PC 端同一已知限制）。
final class YitingshuLocalIndex: @unchecked Sendable {
    static let shared = YitingshuLocalIndex()

    struct Row: Sendable, Equatable {
        let bookId: String
        let title: String
        let cover: String?
    }

    private var rows: [Row]?
    private let lock = NSLock()

    /// 惰性加载（首次搜易听书时才读盘+解析，避免冷启动成本）。
    func all() -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        if let rows { return rows }
        let loaded = Self.load()
        rows = loaded
        return loaded
    }

    private static func load() -> [Row] {
        guard let url = Bundle.main.url(forResource: "yts_index", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var out: [Row] = []
        out.reserveCapacity(17000)
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let bookId = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let title = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !bookId.isEmpty, !title.isEmpty else { continue }
            let cover = parts.count >= 3 ? String(parts[2]) : ""
            out.append(Row(bookId: bookId, title: title,
                           cover: cover.isEmpty ? nil : YitingshuHtml.absCover(cover)))
        }
        return out
    }

    /// 本地检索（与 PC 端 ytsSearchLocal 的评分口径一致）：
    /// 书名大小写不敏感子串命中；前缀命中优先（score 0），其次书名更短者优先，
    /// 末位按 bookId 字典序稳定排序；默认上限 60 条。
    func search(_ keyword: String, limit: Int = 60) -> [MsrcHtml.MsrcSearchItem] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return [] }
        var hits: [(row: Row, score: Int, len: Int)] = []
        for r in all() {
            let t = r.title.lowercased()
            guard let range = t.range(of: kw) else { continue }
            let score = range.lowerBound == t.startIndex ? 0 : 1
            hits.append((r, score, t.count))
        }
        hits.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.len != $1.len { return $0.len < $1.len }
            return $0.row.bookId < $1.row.bookId
        }
        let cap = max(0, limit)
        return hits.prefix(cap).map { h in
            MsrcHtml.MsrcSearchItem(title: h.row.title, author: nil, teller: nil,
                                    cover: h.row.cover,
                                    detailPath: h.row.bookId, bookId: h.row.bookId)
        }
    }

    /// 索引条目数（诊断/测试用，不触发加载时也有准确值：加载后缓存）。
    var count: Int { all().count }
}

// MARK: - 适配器

/// 易听书适配器：单步播放链 + 本地索引兜底搜索 + 分类页。
/// 与 MsrcAdapter（两步 token）形态不同，故独立实现；网络出口复用 APIClient
/// （同一 PinningURLSessionDelegate 会话，出站域名白名单 fail-closed）。
final class YitingshuAdapter: @unchecked Sendable {
    private let apiClient: APIClient
    private let cfg: SourceRegistry.MsrcSourceConfig
    private let index: YitingshuLocalIndex
    /// 详情缓存（同 MsrcAdapter.DetailCache 口径：LRU 8 / TTL 300s）
    private let cache = YtsDetailCache()
    /// 搜索走 live 站点的开关：站点 search.php 一旦命中 gate 就长期置 false（进程内），
    /// 避免每次搜索都白打一次验证码页。
    private var liveSearchUsable = true
    private let liveLock = NSLock()

    init(apiClient: APIClient,
         cfg: SourceRegistry.MsrcSourceConfig = SourceRegistry.msrcSources[SourceRegistry.YITINGSHU]!,
         index: YitingshuLocalIndex = .shared) {
        self.apiClient = apiClient
        self.cfg = cfg
        self.index = index
    }

    private var browserHeaders: [String: String] {
        ["Referer": cfg.referer]
    }

    // MARK: 搜索

    /// 搜索：优先站点 live（受 gate 开关约束），未命中或命中 gate 一律回落本地索引。
    /// 回落不报错——本地索引本身就是设计内的主路径（PC 端 useLocalIndex: true 同口径）。
    func search(keyword: String, limit: Int = 60) async -> [MsrcHtml.MsrcSearchItem] {
        if liveSearchUsable {
            if let live = try? await liveSearch(keyword: keyword, limit: limit), !live.isEmpty {
                return live
            }
        }
        return index.search(keyword, limit: limit)
    }

    /// 站点 live 搜索（search.php）。命中验证码 gate 或解析为空 → 返回 nil 并关闭 live 开关。
    private func liveSearch(keyword: String, limit: Int) async throws -> [MsrcHtml.MsrcSearchItem]? {
        guard var comps = URLComponents(string: cfg.siteBase + "/search.php") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "searchword", value: keyword),
            URLQueryItem(name: "searchtype", value: "1"),
        ]
        guard let url = comps.url else { return nil }
        let html = try await apiClient.fetchHTML(url.absoluteString, headers: browserHeaders)
        if YitingshuHtml.isCaptchaGate(html) {
            liveLock.lock(); liveSearchUsable = false; liveLock.unlock()
            return nil
        }
        let items = YitingshuHtml.parseList(html)
        if items.isEmpty { return nil }
        return Array(items.prefix(max(0, limit)))
    }

    // MARK: 分类

    /// 分类页：GET /yi/{catId}-{page}.html（PC 端口径）。
    /// hasMore 用站点的「当前/总页」判定，取不到时退化为「本页满 30 条」。
    func category(categoryId: String, page: Int) async throws -> (items: [MsrcHtml.MsrcSearchItem], hasMore: Bool) {
        let p = max(1, page)
        guard let url = URL(string: "\(cfg.siteBase)/yi/\(categoryId)-\(p).html") else {
            throw URLError(.badURL)
        }
        let html = try await apiClient.fetchHTML(url.absoluteString, headers: browserHeaders)
        guard !YitingshuHtml.isCaptchaGate(html) else { throw URLError(.resourceUnavailable) }
        let items = YitingshuHtml.parseList(html)
        let hasMore: Bool
        if let cur = YitingshuHtml.currentPage(html), let total = YitingshuHtml.pageCount(html) {
            hasMore = cur < total
        } else {
            hasMore = items.count >= 30
        }
        return (items, hasMore)
    }

    // MARK: 详情

    /// 详情：GET /tingshu/{id}.html，带 LRU+TTL 缓存（同 MsrcAdapter.DetailCache 口径）。
    func detail(bookId: String) async throws -> YitingshuParsedDetail {
        let key = "yts|\(bookId)"
        if let hit = cache.get(key) { return hit }
        guard let url = URL(string: "\(cfg.siteBase)/tingshu/\(bookId).html") else {
            throw URLError(.badURL)
        }
        let html = try await apiClient.fetchHTML(url.absoluteString, headers: browserHeaders)
        guard let parsed = YitingshuHtml.parseDetail(html) else {
            throw URLError(.cannotParseResponse)
        }
        cache.put(key, parsed)
        return parsed
    }

    // MARK: 播放

    /// 播放：GET /play/{bookId}-0-{idx0}.html → 内联 `var now` 直链（单步）。
    /// page 为 1 基章节序（与 Chapter.index 的 0 基差 1），idx0 = page - 1。
    func playUrl(bookId: String, page: Int) async throws -> String {
        let idx0 = max(0, page - 1)
        guard let url = URL(string: "\(cfg.siteBase)/play/\(bookId)-0-\(idx0).html") else {
            throw URLError(.badURL)
        }
        let html = try await apiClient.fetchHTML(url.absoluteString, headers: browserHeaders)
        guard let direct = YitingshuHtml.parsePlayUrl(html, cfg: cfg) else {
            throw URLError(.resourceUnavailable)
        }
        return direct
    }
}

/// 详情缓存（与 MsrcAdapter.DetailCache 同口径：LRU 8 条 / TTL 300 秒）。
final class YtsDetailCache: @unchecked Sendable {
    private var map: [String: (YitingshuParsedDetail, Date)] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    private let ttl: TimeInterval = 300
    private let cap = 8

    func get(_ key: String) -> YitingshuParsedDetail? {
        lock.lock(); defer { lock.unlock() }
        guard let e = map[key] else { return nil }
        guard Date().timeIntervalSince(e.1) < ttl else {
            map.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        order.removeAll { $0 == key }
        order.append(key)
        return e.0
    }

    func put(_ key: String, _ value: YitingshuParsedDetail) {
        lock.lock(); defer { lock.unlock() }
        map[key] = (value, Date())
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > cap {
            let old = order.removeFirst()
            map.removeValue(forKey: old)
        }
    }
}
