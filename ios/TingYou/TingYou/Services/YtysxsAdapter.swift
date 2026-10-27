import Foundation

/// 悦听有声书反爬拦截异常（安卓 AntibotException 对等）。
/// UI 层按此特征捕获，引导用户进 WKWebView 完成人工验证（YtysxsVerifyWebView）。
struct AntibotException: Error {
    let keyword: String
}

/// 悦听有声书（ytysxs.com）适配器（安卓 YtysxsAdapter.kt 的 Swift 移植）。
///
/// 站点链路（WordPress Begin 主题）：
/// - 搜索：`/?s=<kw>` HTML 结果页（article.post → a[href] → h2）；
/// - 详情：`/<bookId>.html`，og:image / og:description 元信息 +
///   `data-tracks-url="…?audioigniter_playlist_id=<pid>"` 播放列表引用（可多个，按序合并）；
/// - 章节：播放列表页返回 AudioIgniter JSON 数组 [{title, subtitle, audio, cover}]，
///   audio 即 mp3.ytysxs.top 直链；
/// - 播放：章节已携直链，playUrl 仅做白名单自检（仅 https + ytysxs.top 域）。
///
/// 反爬处理原则：不自动破解验证码；命中 RE_ANTIBOT 时抛 AntibotException，
/// 由 UI 引导人工验证；验证完成后 token 经 KeychainTokenStore 持久化，24h 内自动携带。
final class YtysxsAdapter: Sendable {

    static let SRC = "ytysxs"
    static let BASE = "https://www.ytysxs.com"
    static let AUDIO_HOST = "mp3.ytysxs.top"
    static let maxBodyBytes = 8 * 1024 * 1024

    private let apiClient: APIClient
    private let cookieStore: KeychainTokenStore?

    init(apiClient: APIClient, cookieStore: KeychainTokenStore? = KeychainTokenStore()) {
        self.apiClient = apiClient
        self.cookieStore = cookieStore
    }

    // ---- 数据形态 ----

    struct YtysxsSearchItem: Sendable, Equatable {
        let title: String
        let detailPath: String
        let bookId: Int64
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

    struct YtysxsChapter: Sendable, Equatable {
        let index: Int
        let title: String
        let subtitle: String
        let audioUrl: String
        let coverUrl: String
    }

    struct Track: Sendable, Equatable {
        let title: String
        let subtitle: String
        let audio: String
        let cover: String
    }

    // ---- 正则（与安卓一致） ----

    static let reAntibot = try! NSRegularExpression(
        pattern: "搜索驗證|搜索验证|安全检查|安全验证|cf-turnstile|be_captcha_token")
    static let reTracksUrl = try! NSRegularExpression(
        pattern: #"data-tracks-url="([^"]*(?:audioigniter/v1/playlist/(\d+)|audioigniter_playlist_id=(\d+))[^"]*)""#)
    static let reBookTitle = try! NSRegularExpression(
        pattern: #"<h1[^>]*class="entry-title"[^>]*>([\s\S]*?)</h1>"#)
    static let reBookCover = try! NSRegularExpression(
        pattern: #"<meta\s+property="og:image"\s+content="([^"]+)""#)
    static let reBookDesc = try! NSRegularExpression(
        pattern: #"<meta\s+property="og:description"\s+content="([^"]+)""#)
    static let reSearchItem = try! NSRegularExpression(
        pattern: #"<article[^>]*>\s*<a\s+href="([^"]+)"[^>]*>[\s\S]*?<h2[^>]*>([\s\S]*?)</h2>"#)
    private static let reBookId = try! NSRegularExpression(pattern: #"/(\d+)\.html"#)
    private static let reTag = try! NSRegularExpression(pattern: #"<[^>]*>"#)

    static func isAntibot(_ html: String) -> Bool {
        let ns = html as NSString
        return reAntibot.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String {
        guard let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ s: String) -> String {
        reTag.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ---- 搜索 ----

    /// 正常结果返回条目；反爬拦截抛 AntibotException（含原始关键词，供 UI 重试）。
    func search(keyword: String) async throws -> [YtysxsSearchItem] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if kw.isEmpty { return [] }
        let html = try await fetchHtml("\(Self.BASE)/?s=\(MsrcHtml.encodeUriComponent(kw))")
        if Self.isAntibot(html) { throw AntibotException(keyword: kw) }
        return Self.parseSearchHtml(html)
    }

    /// 搜索结果 HTML 解析（纯函数，XCTest 黄金样本锁定）
    static func parseSearchHtml(_ html: String) -> [YtysxsSearchItem] {
        var items: [YtysxsSearchItem] = []
        var seen = Set<Int64>()
        let ns = html as NSString
        reSearchItem.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            let href = group(m, 1, in: html)
            let title = stripTags(group(m, 2, in: html))
            guard !title.isEmpty else { return }
            let idNs = href as NSString
            guard let bm = reBookId.firstMatch(in: href, range: NSRange(location: 0, length: idNs.length)),
                  let bookId = Int64(group(bm, 1, in: href)), seen.insert(bookId).inserted else { return }
            items.append(YtysxsSearchItem(title: title, detailPath: href, bookId: bookId))
        }
        return items
    }

    // ---- 详情 ----

    func detail(albumId: Int64) async throws -> YtysxsDetail {
        guard albumId > 0 else { throw URLError(.badURL) }
        let html = try await fetchHtml("\(Self.BASE)/\(albumId).html")
        if Self.isAntibot(html) { throw AntibotException(keyword: "") }
        return Self.parseDetailHtml(html)
    }

    /// 详情页解析（纯函数）
    static func parseDetailHtml(_ html: String) -> YtysxsDetail {
        let title = firstMatch(reBookTitle, 1, in: html)
        let cover = firstMatch(reBookCover, 1, in: html)
        let intro = firstMatch(reBookDesc, 1, in: html)
        var playlists: [PlaylistRef] = []
        var seen = Set<Int64>()
        let ns = html as NSString
        reTracksUrl.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            let url = group(m, 1, in: html)
            // 两种站点形态：…/audioigniter/v1/playlist/<pid>（路径）与 …?audioigniter_playlist_id=<pid>（查询）
            let pid = Int64(group(m, 2, in: html)) ?? Int64(group(m, 3, in: html))
            guard let pid = pid, seen.insert(pid).inserted else { return }
            playlists.append(PlaylistRef(pid: pid, url: url))
        }
        return YtysxsDetail(title: title, cover: cover.isEmpty ? nil : cover,
                            intro: intro.isEmpty ? nil : intro, playlists: playlists)
    }

    // ---- 章节列表 ----

    func chapters(detail: YtysxsDetail) async throws -> [YtysxsChapter] {
        if detail.playlists.isEmpty { return [] }
        var out: [YtysxsChapter] = []
        var index = 1
        for pl in detail.playlists {
            let body = try await fetchHtml(pl.url)
            if Self.isAntibot(body) { throw AntibotException(keyword: "") }
            for t in Self.parseTracksJson(body) {
                out.append(YtysxsChapter(index: index, title: t.title, subtitle: t.subtitle,
                                         audioUrl: t.audio, coverUrl: t.cover))
                index += 1
            }
        }
        return out
    }

    func chapters(albumId: Int64) async throws -> [YtysxsChapter] {
        try await chapters(detail: try await detail(albumId: albumId))
    }

    // ---- 播放地址 ----

    /// 章节直链白名单自检：仅接受 https 且 host 为 ytysxs.top 域。
    func playUrl(chapter: YtysxsChapter) throws -> String {
        let url = chapter.audioUrl
        if url.isEmpty { throw URLError(.badURL) }
        guard let httpUrl = URL(string: url), let scheme = httpUrl.scheme?.lowercased(),
              scheme == "https", let host = httpUrl.host()?.lowercased() else {
            throw URLError(.badURL) // 仅允许 HTTPS 音频地址
        }
        guard host == Self.AUDIO_HOST || host.hasSuffix(".ytysxs.top") else {
            throw URLError(.badURL) // 音频地址不在悦听白名单内，已拦截
        }
        return url
    }

    // ---- JSON 曲目解析（纯函数） ----

    /// 解析 AudioIgniter 播放列表 JSON；缺 title/audio 或 audio 为空的条目跳过；
    /// 空数组 / 非法 JSON → 空列表。
    static func parseTracksJson(_ raw: String) -> [Track] {
        guard let data = raw.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        var out: [Track] = []
        for obj in arr {
            guard let title = obj["title"] as? String, !title.isEmpty,
                  let audio = obj["audio"] as? String, !audio.isEmpty else { continue }
            out.append(Track(title: title,
                             subtitle: obj["subtitle"] as? String ?? "",
                             audio: audio,
                             cover: obj["cover"] as? String ?? ""))
        }
        return out
    }

    // ---- HTTP 基础层（带 cookie 注入；验证通过后 24h 内自动放行） ----

    /// build 41 · 反馈 ②（悦听验证过了但搜索仍被拦）第 1 层：
    /// 此前仅手动拼 `Cookie: be_captcha_token=<token>` 单值头——URLSession 规则是
    /// 「请求已带 Cookie 头时不再自动附加共享 cookie storage 的 cookie」，验证
    /// WebView 建立的会话 cookie（PHPSESSID 等）全部不随请求发出。改为双源合并
    /// 生成单一 Cookie 头。同时显式带 User-Agent = APIClient.browserUA——与验证
    /// WebView 的 customUserAgent 完全一致，避免站点把放行绑定 UA 指纹。
    /// build 42 · 任务二第 2 层（path 嫌疑，单测裁决见
    /// YtysxsCookieMatchingTests）：HTTPCookieStorage.cookies(for:) 按 RFC 6265
    /// 严格 path 匹配——服务器经 admin-ajax.php（/wp-admin/ 路径）Set-Cookie 的
    /// cookie 若 path 非根，对搜索 URL（path=/）会被**静默漏掉**。因此不再用
    /// cookies(for:) 过滤，改为 storage 全量取出，由 mergedCookieHeader 自实现
    /// domain 匹配（host 精确或父域命中）+ path 放宽（域内 cookie 一律携带）。
    private func fetchHtml(_ url: String) async throws -> String {
        var headers: [String: String] = [
            "User-Agent": APIClient.browserUA,
        ]
        if let urlObj = URL(string: url) {
            let allCookies = HTTPCookieStorage.shared.cookies ?? []
            if let header = Self.mergedCookieHeader(url: urlObj,
                                                    storageCookies: allCookies,
                                                    keychainHeaderValue: cookieStore?.cookieHeaderValue()) {
                headers["Cookie"] = header
            }
        } else if let kv = cookieStore?.cookieHeaderValue() {
            // URL 不可解析的兜底分支（理论不可达，保留旧行为）
            headers["Cookie"] = kv
        }
        return try await apiClient.fetchHTML(url, headers: headers)
    }

    // ---- build 42 · 任务二：cookie 合并纯函数（单测注入构造 cookie 裁决） ----

    /// domain 匹配（RFC 6265 放宽实现）：cookie 域去掉前导点后，与请求 host
    /// 精确相等或为其父域（host 以 ".域" 结尾）即命中。dotless 域
    /// （"ytysxs.com"）与带点域（".ytysxs.com"）对 www.ytysxs.com 同样命中。
    static func domainMatches(host: String, cookieDomain: String) -> Bool {
        let h = host.lowercased()
        let d = cookieDomain.lowercased()
        let trimmed = d.hasPrefix(".") ? String(d.dropFirst()) : d
        guard !trimmed.isEmpty else { return false }
        return h == trimmed || h.hasSuffix("." + trimmed)
    }

    /// 双源合并（build 41 引入，build 42 改 path 放宽）：
    /// storage 域内全部 cookie（含 path 非根的——修复 cookies(for:) 静默漏发）
    /// + Keychain be_captcha_token 兜底（storage 域内已有同名则不重复注入，
    /// 早期会话 / 部分同步失败时由 Keychain 兜底）。
    /// 返回单一 Cookie 头值；无任何 cookie 时返回 nil（不带 Cookie 头，
    /// URLSession 会自动附加 storage 匹配 cookie——保持兜底行为不变）。
    static func mergedCookieHeader(url: URL,
                                   storageCookies: [HTTPCookie],
                                   keychainHeaderValue: String?) -> String? {
        let host = url.host ?? ""
        var parts: [String] = []
        var names = Set<String>()
        for cookie in storageCookies where domainMatches(host: host, cookieDomain: cookie.domain) {
            names.insert(cookie.name)
            parts.append("\(cookie.name)=\(cookie.value)")
        }
        if let kv = keychainHeaderValue, !names.contains("be_captcha_token") {
            parts.append(kv)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private static func firstMatch(_ re: NSRegularExpression, _ i: Int, in s: String) -> String {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return "" }
        return group(m, i, in: s)
    }
}
