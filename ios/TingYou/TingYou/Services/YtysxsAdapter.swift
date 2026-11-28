import Foundation

/// 悦听有声书（ytysxs.com）适配器。
///
/// v2.0.2 重新接入（对齐用户「按原有节奏接入音源，并拉取分类/封面」）：
/// - 搜索 / 发现分类：读随包本地索引 ytysxs_index.txt（title|cover|category），
///   零网络请求——彻底规避站点站内搜索的滑块验证，离线可用。
/// - 详情：`/<bookId>.html` 解析 og:title / og:image / data-tracks-url 播放列表引用。
/// - 章节：AudioIgniter playlist JSON 的 tracks（audio 即 mp3.ytysxs.top 直链）。
/// - 播放：章节直链白名单自检（仅 https 且 host 为 ytysxs.top 域）。
///
/// 稳定性约定（用户确认方案）：
/// - 验证页检测：详情/章节返回内容命中 captcha 特征时抛 YtysxsUnavailableError，
///   UI 明确提示「暂不可用，可切换其他音源」，不把验证页当数据解析（避免误报「加载成功」）。
/// - 缓存兜底：详情与章节进程内缓存，命中即返回；索引常驻随包，网络失败时分类/封面仍有数据。
/// - 合规底线：不识别/伪造验证码、不模拟滑块轨迹；仅访问站点公开页面与公开 JSON。
actor YtysxsAdapter: Sendable {

    static let SRC = "ytysxs"
    static let BASE = "https://www.ytysxs.com"
    static let AUDIO_HOST = "mp3.ytysxs.top"

    /// 站点验证/反爬拦截特征（命中即视为「源暂不可用」，不做自动绕过）。
    static let antibotPatterns = [
        "搜索驗證", "搜索验证", "安全检查", "安全验证",
        "cf-turnstile", "be_captcha_token", "滑动验证", "滑块验证",
    ]

    /// 悦听源暂不可用（站点验证拦截 / 非 JSON 响应）。UI 按 LocalizedError 文案透出。
    struct YtysxsUnavailableError: LocalizedError, Sendable {
        let detail: String
        var errorDescription: String? {
            "悦听音源暂时不可用（\(detail)），请稍后重试或切换其他音源"
        }
    }

    // ---- 数据形态 ----

    struct IndexRow: Sendable, Equatable {
        let bookId: Int64
        let title: String
        let cover: String?
        let category: String
    }

    struct PlaylistRef: Sendable, Equatable {
        let pid: Int64
        let url: String
    }

    struct YtysxsDetail: Sendable, Equatable {
        let title: String
        let cover: String?
        let intro: String?
        let playlists: [PlaylistRef]
    }

    struct Track: Sendable, Equatable {
        let title: String
        let subtitle: String
        let audio: String
        let cover: String
    }

    // ---- 正则 ----

    private static let reTracksUrl = try! NSRegularExpression(
        pattern: #"data-tracks-url="([^"]*(?:audioigniter/v1/playlist/(\d+)|audioigniter_playlist_id=(\d+))[^"]*)""#)
    private static let reOgTitle = try! NSRegularExpression(
        pattern: #"<meta\s+property="og:title"\s+content="([^"]+)""#)
    private static let reOgImage = try! NSRegularExpression(
        pattern: #"<meta\s+property="og:image"\s+content="([^"]+)""#)
    private static let reOgDesc = try! NSRegularExpression(
        pattern: #"<meta\s+property="og:description"\s+content="([^"]+)""#)
    private static let reEntryTitle = try! NSRegularExpression(
        pattern: #"<h1[^>]*class="entry-title"[^>]*>([\s\S]*?)</h1>"#)
    private static let reTag = try! NSRegularExpression(pattern: #"<[^>]*>"#)

    private let apiClient: APIClient
    private var indexCache: [IndexRow]?
    private var detailCache: [Int64: YtysxsDetail] = [:]
    private var tracksCache: [Int64: [Track]] = [:]

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // ---- 验证页检测（纯函数） ----

    static func isAntibot(_ text: String) -> Bool {
        antibotPatterns.contains { text.localizedCaseInsensitiveContains($0) }
    }

    // ---- 本地索引（纯函数 + 随包加载） ----

    /// 解析索引文本：每行 `bookId|title|cover|category`，标题中的 `|` 已在生成阶段替换。
    static func parseIndex(_ raw: String) -> [IndexRow] {
        var rows: [IndexRow] = []
        var seen = Set<Int64>()
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 4,
                  let bid = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
                  !parts[1].isEmpty, seen.insert(bid).inserted else { continue }
            let cover = parts[2].isEmpty ? nil : String(parts[2])
            rows.append(IndexRow(bookId: bid,
                                 title: String(parts[1]),
                                 cover: cover,
                                 category: String(parts[3])))
        }
        return rows
    }

    /// 本地索引搜索：前缀命中优先，其次子串命中；同档按标题长度升序（短标题更相关）。
    /// 纯函数，XCTest 可用黄金样本锁定。
    static func searchIndex(_ rows: [IndexRow], keyword: String) -> [IndexRow] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return [] }
        var prefix: [IndexRow] = []
        var substring: [IndexRow] = []
        for row in rows {
            let t = row.title.lowercased()
            // 书名号开头（《关键词》）与裸开头都算前缀命中
            if t.hasPrefix("《" + kw) || t.hasPrefix(kw) {
                prefix.append(row)
            } else if t.contains(kw) {
                substring.append(row)
            }
        }
        prefix.sort { $0.title.count < $1.title.count }
        substring.sort { $0.title.count < $1.title.count }
        return Array((prefix + substring).prefix(30))
    }

    /// 随包索引只读一次（actor 内缓存）。缺失时返回空数组，UI 如实显示无结果。
    private func loadIndex() -> [IndexRow] {
        if let cache = indexCache { return cache }
        guard let url = Bundle.main.url(forResource: "ytysxs_index", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            indexCache = []
            return []
        }
        let rows = Self.parseIndex(raw)
        indexCache = rows
        return rows
    }

    func search(keyword: String) -> [IndexRow] {
        Self.searchIndex(loadIndex(), keyword: keyword)
    }

    /// 发现分类：从本地索引按 category 过滤（零网络），返回书籍行。
    func categoryRows(categoryId: String, page: Int, pageSize: Int = 20) -> (rows: [IndexRow], hasMore: Bool) {
        let all = loadIndex().filter { $0.category == categoryId }
        let start = max(0, (page - 1) * pageSize)
        guard start < all.count else { return ([], false) }
        let end = min(start + pageSize, all.count)
        return (Array(all[start..<end]), end < all.count)
    }

    // ---- 详情 ----

    func detail(albumId: Int64) async throws -> YtysxsDetail {
        if let cached = detailCache[albumId] { return cached }
        guard albumId > 0 else { throw URLError(.badURL) }
        let html = try await fetchHtml("\(Self.BASE)/\(albumId).html")
        guard !Self.isAntibot(html) else {
            throw YtysxsUnavailableError(detail: "站点验证拦截")
        }
        let detail = Self.parseDetailHtml(html)
        detailCache[albumId] = detail
        return detail
    }

    /// 详情页解析（纯函数）：og:title 优先、h1.entry-title 兜底；封面 og:image；
    /// 简介 og:description；播放列表 data-tracks-url（路径式与查询式均支持）。
    static func parseDetailHtml(_ html: String) -> YtysxsDetail {
        let title = firstMatch(reOgTitle, 1, in: html).isEmpty
            ? decode(Self.stripTags(firstMatch(reEntryTitle, 1, in: html)))
            : decode(firstMatch(reOgTitle, 1, in: html))
        let cover = firstMatch(reOgImage, 1, in: html)
        let intro = decode(firstMatch(reOgDesc, 1, in: html))
        var playlists: [PlaylistRef] = []
        var seen = Set<Int64>()
        let ns = html as NSString
        reTracksUrl.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            let url = group(m, 1, in: html)
            let pid = Int64(group(m, 2, in: html)) ?? Int64(group(m, 3, in: html))
            guard let pid = pid, seen.insert(pid).inserted else { return }
            playlists.append(PlaylistRef(pid: pid, url: url))
        }
        return YtysxsDetail(title: title,
                            cover: cover.isEmpty ? nil : cover,
                            intro: intro.isEmpty ? nil : intro,
                            playlists: playlists)
    }

    // ---- 章节 ----

    func chapters(albumId: Int64) async throws -> [Track] {
        if let cached = tracksCache[albumId] { return cached }
        let detail = try await detail(albumId: albumId)
        guard !detail.playlists.isEmpty else { return [] }
        var out: [Track] = []
        for pl in detail.playlists {
            let body = try await fetchHtml(pl.url)
            guard !Self.isAntibot(body) else {
                throw YtysxsUnavailableError(detail: "章节列表验证拦截")
            }
            out.append(contentsOf: Self.parseTracksJson(body))
        }
        tracksCache[albumId] = out
        return out
    }

    /// AudioIgniter playlist JSON 解析（纯函数）：缺 title/audio 或 audio 为空的条目跳过。
    /// 返回空数组即视为「章节暂不可用」，由调用方给出明确提示，不静默当成功。
    static func parseTracksJson(_ raw: String) -> [Track] {
        guard let data = raw.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        var out: [Track] = []
        for obj in arr {
            guard let title = obj["title"] as? String, !title.isEmpty,
                  let audio = obj["audio"] as? String, !audio.isEmpty else { continue }
            out.append(Track(title: decode(title),
                             subtitle: decode(obj["subtitle"] as? String ?? ""),
                             audio: audio,
                             cover: obj["cover"] as? String ?? ""))
        }
        return out
    }

    // ---- 播放地址 ----

    /// 按 albumId + chapterIdx 取直链（复用章节缓存，缓存未命中则重新拉取章节）。
    func playUrl(albumId: Int64, chapterIdx: Int) async throws -> String {
        let tracks = try await chapters(albumId: albumId)
        guard chapterIdx >= 0, chapterIdx < tracks.count else {
            throw URLError(.resourceUnavailable)
        }
        return try Self.validateAudioUrl(tracks[chapterIdx].audio)
    }

    /// 音频直链白名单自检（纯函数）：仅 https 且 host 为 ytysxs.top 或其子域。
    static func validateAudioUrl(_ url: String) throws -> String {
        guard !url.isEmpty,
              let u = URL(string: url),
              let scheme = u.scheme?.lowercased(), scheme == "https",
              let host = u.host()?.lowercased() else {
            throw URLError(.badURL)
        }
        guard host == AUDIO_HOST || host.hasSuffix(".ytysxs.top") else {
            throw URLError(.badURL) // 音频地址不在悦听白名单内，已拦截
        }
        return url
    }

    // ---- HTTP ----

    private func fetchHtml(_ url: String) async throws -> String {
        try await apiClient.fetchHTML(url, headers: ["User-Agent": APIClient.browserUA])
    }

    // ---- 纯函数工具 ----

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String {
        guard let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(_ re: NSRegularExpression, _ i: Int, in s: String) -> String {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return "" }
        return group(m, i, in: s)
    }

    private static func stripTags(_ s: String) -> String {
        reTag.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    private static func decode(_ s: String) -> String {
        MsrcHtml.decodeHTMLEntities(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
