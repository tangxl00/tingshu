import Foundation
import CoreFoundation

/// build 36 · 反馈 1（59听书搜索无结果）：站点级人机验证拦截异常。
/// 沙箱实测：首页正常（200），但 /search.php?searchword=... 返回 3022 字节 GBK 编码
/// 的「系统安全验证」验证码页（vdcode 表单），携带首页 Cookie 后依然拦截——按请求级
/// 验证码，与悦听 cf-turnstile 不同类，且不做自动破解。语义上与悦听 AntibotException
/// 严格隔离：后者驱动悦听专属验证闭环（AggregateSearch.antibotKeyword →
/// YtysxsVerifySheet），本异常仅如实报错 + 音源管理标注，避免误触发悦听验证 UI。
struct Ting59AntibotException: LocalizedError {
    var errorDescription: String? {
        "59听书需要安全验证，本次请求被站点拦截，请稍后重试"
    }
}

// build 29 · 59听书网适配器（设计文档 10.1.4 / 10.2 语义移植）。
// 站点画像：免费公开 HTML 站，无登录态、无 API 签名、无风控；
// 页面：搜索 /search.php?searchword={kw}&page={p}、
//       分类 /book/{id}.html（分页 /book/{id}-{p}.html）、
//       详情 /mp3/{书ID}.html、
//       播放 /play/{书ID}-{线路}-{序号}.html（line=0 为实际有效线路）。

actor Ting59Adapter {
    static let BASE_URL = "https://www.ting59.com"

    /// 页面抓取 User-Agent（带浏览器 UA 防站点 UA 拦截）
    static let USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// 请求限速：最小间隔 500ms ≈ 2 req/s
    static let MIN_REQUEST_GAP_MS: UInt64 = 500_000_000

    /// 响应体大小上限（防异常页拖垮内存）
    private static let MAX_BODY_BYTES: Int64 = 8 * 1024 * 1024

    private let baseUrl: String
    private var lastRequestAt: UInt64 = 0

    init(baseUrl: String = BASE_URL) {
        self.baseUrl = baseUrl
    }

    // MARK: - 请求节流

    private func throttle() async {
        let now = DispatchTime.now().uptimeNanoseconds
        let wait = (lastRequestAt + Ting59Adapter.MIN_REQUEST_GAP_MS > now)
            ? lastRequestAt + Ting59Adapter.MIN_REQUEST_GAP_MS - now
            : 0
        if wait > 0 {
            try? await Task.sleep(nanoseconds: wait)
        }
        lastRequestAt = DispatchTime.now().uptimeNanoseconds
    }

    // MARK: - 搜索

    /// 与 Ting59ListParsers 的同名结果类型统一，避免同名不同型的冲突
    typealias Ting59SearchResult = Ting59ListParsers.Ting59SearchResult

    struct Ting59SearchItem: Sendable {
        let id: String
        let title: String
        let author: String?
        let narrator: String?
        let category: String?
        let updateTime: String?
        let detailUrl: String
    }

    func search(query: String, page: Int) async throws -> Ting59SearchResult {
        let doc = try await fetchSearchPage(query: query, page: page)
        return Ting59ListParsers.parseSearch(doc: doc)
    }

    func fetchSearchPage(query: String, page: Int) async throws -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "\(baseUrl)/search.php?searchword=\(encoded)&page=\(page)"
        return try await fetchHtml(url: url, throttled: true)
    }

    // MARK: - 分类

    /// 与 Ting59ListParsers 的同名结果类型统一，避免同名不同型的冲突
    typealias Ting59CategoryResult = Ting59ListParsers.Ting59CategoryResult

    func category(categoryId: String, page: Int) async throws -> Ting59CategoryResult {
        let doc = try await fetchCategoryPage(categoryId: categoryId, page: page)
        return Ting59ListParsers.parseCategory(doc: doc)
    }

    func fetchCategoryPage(categoryId: String, page: Int) async throws -> String {
        let url = page <= 1
            ? "\(baseUrl)/book/\(categoryId).html"
            : "\(baseUrl)/book/\(categoryId)-\(page).html"
        return try await fetchHtml(url: url, throttled: true)
    }

    // MARK: - 详情

    struct Ting59BookDetail: Sendable {
        let book: Ting59SearchItem
        let chapters: [Ting59Chapter]
        let description: String?
        let coverUrl: String?
    }

    struct Ting59Chapter: Sendable {
        let index: Int
        let title: String
    }

    func bookDetail(bookId: String) async throws -> Ting59BookDetail {
        let doc = try await fetchBookDetailPage(bookId: bookId)
        return try Ting59DetailParser.parse(bookId: bookId, html: doc)
    }

    func fetchBookDetailPage(bookId: String) async throws -> String {
        let url = "\(baseUrl)/mp3/\(bookId).html"
        return try await fetchHtml(url: url, throttled: true)
    }

    // MARK: - 播放页

    func fetchPlayPage(bookId: String, line: Int = 0, index: Int) async throws -> String {
        let url = "\(baseUrl)/play/\(bookId)-\(line)-\(index).html"
        return try await fetchHtml(url: url, throttled: false)
    }

    // MARK: - 通用抓取

    private func fetchHtml(url: String, throttled: Bool) async throws -> String {
        guard let urlObj = URL(string: url),
              let host = urlObj.host else {
            throw URLError(.badURL)
        }
        let baseHost = URL(string: baseUrl)?.host ?? ""
        guard host == baseHost || Ting59Source.hostAllowed(host) else {
            throw URLError(.badURL)
        }

        if throttled { await throttle() }

        var request = URLRequest(url: urlObj)
        request.setValue(Ting59Adapter.USER_AGENT, forHTTPHeaderField: "User-Agent")
        request.setValue(baseUrl, forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw URLError(.fileDoesNotExist)
            } else if (500...599).contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            } else {
                throw URLError(.badServerResponse)
            }
        }
        guard Int64(data.count) <= Ting59Adapter.MAX_BODY_BYTES else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        guard let html = Self.decodeBody(data), !html.isEmpty else {
            throw URLError(.badServerResponse)
        }
        // build 36 · 反馈 1：命中站点级「系统安全验证」验证码页 → 明确报错，
        // 不静默返回空结果（0 结果误导用户以为无此书）。
        if Self.isAntibotPage(html) {
            throw Ting59AntibotException()
        }
        return html
    }

    /// 页面混合编码兜底（build 36）：常规页 UTF-8；站点级安全验证页为 GBK
    /// （沙箱实测 3022 字节，UTF-8 解码为 nil 会被误判为坏响应）。UTF-8 失败时
    /// 按 GB18030（GBK 超集）兜底解码。
    static func decodeBody(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: gbk)
    }

    /// 站点级安全验证页特征（沙箱实测）：页面含「系统安全验证」文案或 vdcode 验证表单。
    static func isAntibotPage(_ html: String) -> Bool {
        html.contains("系统安全验证") || html.contains("vdcode")
    }
}
