import Foundation
import CryptoKit

/// 书音 FM（mekui.com）适配器（安卓 MekuiAdapter.kt 的 Swift 移植，v1.3.3）。
///
/// - 搜索：站点自身 `/api/search/ecms`（Next API，无需 token）；
/// - 详情/章节：ecmsapi `mod=movie&act=detail|movielist`（须带浏览器 UA，否则 403）；
/// - 播放直链：ecmsapi `act=wapseries` —— 参数 {act, mod, id, movieId, t} 按键排序拼 `k=v&`，
///   追加 `&token=<公开站点token>` 后取 MD5，与站点公开 JS（chunk 0wzgnnooopbwm.js 模块 84423
///   function h）完全一致的公开算法，无破解成分；
/// - 响应 data.signed_urls[] / SeriesUrl 为预签名直链（mp3 优先），出站前过源白名单自检；
/// - 站点突发限频（502）由 APIClient 的 RetryConfig.mekui（2 次 / [2.5s, 8s]）退避重试。
final class MekuiAdapter: Sendable {

    static let SEARCH_PAGE_SIZE = 20
    static let SITE_BASE = "https://m.mekui.com"
    static let SEARCH_API = "\(SITE_BASE)/api/search/ecms"
    static let ECMSAPI = "\(SITE_BASE)/ecmsapi/index.php"
    static let SITE_TOKEN = "056a308c515e16b2fe5a5c631319339cbc60a8ee0e03d016"

    private let apiClient: APIClient
    private let paidChapters: PaidChapterRegistry
    private let config: SourceRegistry.MsrcSourceConfig

    /// build 37 · 反馈 1：mekui 源下架（SourceRegistry.mekui config 删除）——
    /// 本适配器按 build 36 删 ting08 的模式保留（签名算法与解析黄金样本由
    /// MekuiAdapterTests 离线守护）；config 改为必填参数，生产装配点已摘除。
    init(apiClient: APIClient,
         paidChapters: PaidChapterRegistry = .shared,
         config: SourceRegistry.MsrcSourceConfig) {
        self.apiClient = apiClient
        self.paidChapters = paidChapters
        self.config = config
    }

    // ---- 数据形态 ----

    struct MekuiSearchItem: Sendable, Equatable {
        let id: String
        let classid: String
        let title: String
        let titlepic: String
        let playadmin: String
        let player: String
        let keyboard: String
    }

    struct MekuiSearchPage: Sendable, Equatable {
        let items: [MekuiSearchItem]
        let hasMore: Bool
    }

    struct MekuiChapter: Sendable, Equatable {
        let id: String   // movielist 条目 id（即 wapseries 的 movieId）
        let index: Int
        let title: String
        let paid: Bool
    }

    struct MekuiDetail: Sendable, Equatable {
        let id: String
        let title: String
        let cover: String
        let artist: String
        let player: String
        let description: String
        let category: String
        let keywords: String
        let chapters: [MekuiChapter]
    }

    // ---- 搜索（站点自身 /api/search/ecms） ----

    func search(keyword: String, page: Int = 1) async throws -> MekuiSearchPage {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard page >= 1 else { throw URLError(.badURL) }
        if kw.isEmpty { return MekuiSearchPage(items: [], hasMore: false) }
        let url = "\(Self.SEARCH_API)?keyword=\(Self.queryEncode(kw))&page=\(page)&pageSize=\(Self.SEARCH_PAGE_SIZE)"
        let json = try await apiClient.fetchJSON(url, headers: ["Referer": "\(Self.SITE_BASE)/"])
        guard (json["code"] as? Int) == 1, let data = json["data"] as? [String: Any] else {
            return MekuiSearchPage(items: [], hasMore: false)
        }
        let arr = data["list"] as? [[String: Any]] ?? []
        let items = arr.map { o in
            MekuiSearchItem(
                id: o["id"] as? String ?? "",
                classid: o["classid"] as? String ?? "",
                title: o["title"] as? String ?? "",
                titlepic: o["titlepic"] as? String ?? "",
                playadmin: o["playadmin"] as? String ?? "",
                player: o["player"] as? String ?? "",
                keyboard: o["keyboard"] as? String ?? "")
        }
        let total = data["total"] as? Int ?? 0
        let totalPage = data["totalpage"] as? Int ?? 1
        return MekuiSearchPage(items: items,
                               hasMore: !items.isEmpty && page < totalPage && total > 0)
    }

    // ---- 详情（专辑 + 章节） ----

    func detail(id: String) async throws -> MekuiDetail {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { throw URLError(.badURL) }
        let detailJson = try await apiClient.fetchJSON(
            "\(Self.ECMSAPI)?token=\(Self.SITE_TOKEN)&mod=movie&act=detail&id=\(Self.queryEncode(id))",
            headers: ["Referer": "\(Self.SITE_BASE)/"])
        let chaptersJson = try await apiClient.fetchJSON(
            "\(Self.ECMSAPI)?token=\(Self.SITE_TOKEN)&mod=movie&act=movielist&id=\(Self.queryEncode(id))&pn=1",
            headers: ["Referer": "\(Self.SITE_BASE)/"])
        return try Self.parseDetail(detailJson, chaptersJson, id: id)
    }

    /// 详情/章节解析（纯函数，XCTest 黄金样本锁定）
    static func parseDetail(_ detailJson: [String: Any], _ chaptersJson: [String: Any], id: String) throws -> MekuiDetail {
        guard let detail = (detailJson["data"] as? [String: Any])?["detail"] as? [String: Any] else {
            throw URLError(.cannotParseResponse) // 详情响应缺少 data.detail
        }
        let list = (chaptersJson["data"] as? [String: Any])?["moielist"] as? [[String: Any]] ?? []
        var chapters: [MekuiChapter] = []
        for (i, c) in list.enumerated() {
            let cid = c["id"] as? String ?? ""
            let numericId = Int(cid)
            let level = c["level"] as? String ?? "0"
            let control = c["control"] as? String ?? "0"
            chapters.append(MekuiChapter(
                id: cid,
                // 实测 movielist 条目 id 即 wapseries 的 movieId（与站点 JS 用序号一致）
                index: numericId ?? (i + 1),
                title: c["title"] as? String ?? "",
                paid: (Int(level) ?? 0) != 0 || (Int(control) ?? 0) != 0))
        }
        return MekuiDetail(
            id: id,
            title: detail["title"] as? String ?? "",
            cover: detail["titlepic"] as? String ?? "",
            artist: detail["playadmin"] as? String ?? "",
            player: detail["player"] as? String ?? "",
            description: detail["moviesay"] as? String ?? "",
            category: detail["firstclassname"] as? String ?? "",
            keywords: detail["keyboard"] as? String ?? "",
            chapters: chapters)
    }

    // ---- 播放（ecmsapi wapseries 预签名直链） ----

    /// markPaid=false 时探测到付费不打标（只抛 PaidChapterException），供预加载静默跳过。
    func getPlayUrl(albumId: String, chapterIdx: Int, markPaid: Bool = true, knownChapters: [MekuiChapter] = []) async throws -> String {
        guard !albumId.isEmpty, albumId.allSatisfy(\.isNumber), chapterIdx >= 1 else {
            throw URLError(.badURL)
        }
        let paidKey = "\(config.id):\(albumId):\(chapterIdx)"
        if paidChapters.contains(paidKey) {
            throw PaidChapterException(src: config.id, albumId: albumId, chapter: String(chapterIdx))
        }

        // 章节实际 movieId：优先已知章节列表（实测与站点 JS 一致）
        let movieId = knownChapters.first(where: { $0.index == chapterIdx })?.id ?? String(chapterIdx)

        let t = String(Int(Date().timeIntervalSince1970))
        let sig = Self.wapseriesSignature(albumId: albumId, movieId: movieId, t: t)
        let json = try await apiClient.fetchJSON(
            "\(Self.ECMSAPI)?act=wapseries&mod=movie&id=\(albumId)&movieId=\(movieId)&t=\(t)&token=\(sig)",
            headers: ["Referer": "\(Self.SITE_BASE)/"])

        guard (json["code"] as? Int) == 1 else {
            let msg = json["message"] as? String ?? "获取播放地址失败"
            if msg.contains("积分") || msg.contains("会员") || msg.contains("VIP") {
                if markPaid { paidChapters.mark(paidKey) }
                throw PaidChapterException(src: config.id, albumId: albumId, chapter: String(chapterIdx))
            }
            if msg.contains("登录") { throw URLError(.userAuthenticationRequired) }
            throw URLError(.badServerResponse)
        }
        guard let data = json["data"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if (data["ispass"] as? Int ?? 1) != 1 {
            if markPaid { paidChapters.mark(paidKey) }
            throw PaidChapterException(src: config.id, albumId: albumId, chapter: String(chapterIdx))
        }

        // 候选直链：signed_urls（预签名 https）优先，SeriesUrl 兜底；只取 https；mp3 优先。
        var candidates: [String] = []
        for u in data["signed_urls"] as? [String] ?? [] where u.hasPrefix("https://") {
            candidates.append(u)
        }
        if let series = data["SeriesUrl"] as? String, series.hasPrefix("https://") {
            candidates.append(series)
        }
        guard !candidates.isEmpty else { throw URLError(.badServerResponse) }

        let chosen = candidates.first { $0.split(separator: "?")[0].hasSuffix(".mp3") } ?? candidates[0]
        guard let httpUrl = URL(string: chosen), let host = httpUrl.host() else {
            throw URLError(.badURL)
        }
        guard SourceRegistry.audioHostAllowed(cfg: config, host: host) else {
            throw URLError(.badURL) // 音频地址不在源白名单内，已拦截
        }
        return chosen
    }

    // ---- 公开签名算法（站点 JS 模块 84423 function h，纯函数供单测黄金值锁定） ----

    /// 参数按键排序拼 `k=v&`，追加 `&token=<SITE_TOKEN>` 后取 MD5 hex。
    static func wapseriesSignature(albumId: String, movieId: String, t: String) -> String {
        let params: [String: String] = [
            "act": "wapseries",
            "mod": "movie",
            "id": albumId,
            "movieId": movieId,
            "t": t,
        ]
        let sorted = params.keys.sorted().map { k in "\(k)=\(params[k]!)" }.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data("\(sorted)&token=\(Self.SITE_TOKEN)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func queryEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
