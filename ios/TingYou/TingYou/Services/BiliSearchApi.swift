import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// B站站内搜索 API（build 29 · WBI 签名 + 有声内容过滤）
actor BiliSearchApi {
    static let PAGE_SIZE = 20
    static let MAX_PAGE = 50
    static let SUPPLEMENT_THRESHOLD = 6
    static let SUFFIX = "有声小说"
    static let WBI_KEY_TTL_MS: UInt64 = 600_000
    static let RETRY_GAP_MS: UInt64 = 1_200

    /// WBI 密钥重排索引表（官方固定 64 位顺序，取前 32 位）
    static let MIXIN_KEY_ENC_TAB: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
    ]

    private let adapter: BiliAdapter
    private let apiBase: String

    private var cachedWbiKey: String?
    private var wbiKeyFetchedAt: UInt64 = 0

    init(adapter: BiliAdapter, apiBase: String = "https://api.bilibili.com") {
        self.adapter = adapter
        self.apiBase = apiBase
    }

    // MARK: - 数据模型

    struct SearchResult: Sendable {
        let bvid: String
        let title: String
        let author: String
        let coverUrl: String?
        let durationSec: Int64?
        let play: Int64
        let description: String
        let tag: String
        let typeId: Int
        let paid: Bool
    }

    struct SearchPage: Sendable {
        let items: [SearchResult]
        let page: Int
        let numPages: Int
        let numResults: Int
        let hasMore: Bool
    }

    // MARK: - WBI 密钥

    private func wbiKey() async throws -> String {
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        if let key = cachedWbiKey, now - wbiKeyFetchedAt < Self.WBI_KEY_TTL_MS { return key }
        let json = try await adapter.getJson(url: "\(apiBase)/x/web-interface/nav")
        guard let data = json["data"] as? [String: Any],
              let wbi = data["wbi_img"] as? [String: Any],
              let img = wbi["img_url"] as? String, !img.isEmpty,
              let sub = wbi["sub_url"] as? String, !sub.isEmpty else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "WBI 密钥获取失败"])
        }
        let key = Self.mixinKey(imgUrl: img, subUrl: sub)
        cachedWbiKey = key
        wbiKeyFetchedAt = now
        return key
    }

    /// 官方 mixinKey 重排
    static func mixinKey(imgUrl: String, subUrl: String) -> String {
        let raw = rawKeySource(imgUrl) + rawKeySource(subUrl)
        let arr = Array(raw)
        let reordered = Self.MIXIN_KEY_ENC_TAB.compactMap { arr.indices.contains($0) ? String(arr[$0]) : nil }
        return reordered.joined().prefix(32).map { String($0) }.joined()
    }

    private static func rawKeySource(_ url: String) -> String {
        url.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? ""
    }

    // MARK: - 搜索

    func searchAudiobooks(keyword: String, page: Int) async throws -> SearchPage {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "搜索关键词不能为空"])
        }
        guard page >= 1 else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "页码必须 ≥ 1"])
        }
        if page > Self.MAX_PAGE {
            return SearchPage(items: [], page: page, numPages: Self.MAX_PAGE, numResults: 0, hasMore: false)
        }
        let wbi = try await wbiKey()
        let wts = UInt64(Date().timeIntervalSince1970)
        let url = Self.buildSearchUrl(apiBase: apiBase, keyword: kw, page: page,
                                       order: BiliCategories.ORDER_TOTALRANK, wbiKey: wbi, wtsSeconds: wts)
        let json = try await adapter.getJson(url: url)
        let code = json["code"] as? Int ?? -1
        if code != 0 {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "B站搜索失败：code=\(code) \(json["message"] as? String ?? "")"])
        }
        guard let data = json["data"] as? [String: Any] else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "B站搜索响应缺少 data"])
        }
        let items = parseItems(data["result"] as? [[String: Any]] ?? [])
        let numPages = data["numPages"] as? Int ?? 1
        let hasMore = !items.isEmpty && page < numPages && page < Self.MAX_PAGE
        return SearchPage(items: items, page: page, numPages: numPages,
                           numResults: data["numResults"] as? Int ?? 0, hasMore: hasMore)
    }

    // MARK: - URL 构造

    static func buildSearchUrl(apiBase: String, keyword: String, page: Int, order: String,
                                wbiKey: String, wtsSeconds: UInt64, duration: Int = 0) -> String {
        let params: [(String, String)] = [
            ("duration", String(duration)),
            ("keyword", keyword),
            ("order", order),
            ("page", String(page)),
            ("page_size", String(Self.PAGE_SIZE)),
            ("search_type", "video"),
            ("wts", String(wtsSeconds)),
        ]
        let sorted = params.sorted { $0.0 < $1.0 }
        let query = sorted.map { "\($0.0)=\(encodeValue($0.1))" }.joined(separator: "&")
        let wRid = md5Hex(query + wbiKey)
        return "\(apiBase)/x/web-interface/wbi/search/type?\(query)&w_rid=\(wRid)"
    }

    static func encodeValue(_ raw: String) -> String {
        var sb = ""
        for ch in raw {
            if "!'()*".contains(ch) {
                sb += String(format: "%%%02X", ch.asciiValue ?? 0)
            } else {
                sb.append(ch)
            }
        }
        return sb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sb
    }

    static func md5Hex(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "" }
        #if canImport(CryptoKit)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        // Fallback: CommonCrypto
        var digest = [UInt8](repeating: 0, count: 16)
        data.withUnsafeBytes { bytes in
            _ = CC_MD5(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
        #endif
    }

    // MARK: - 解析

    private func parseItems(_ arr: [[String: Any]]) -> [SearchResult] {
        arr.compactMap { parseItem($0) }
    }

    private func parseItem(_ o: [String: Any]) -> SearchResult? {
        let bvid = (o["bvid"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !bvid.isEmpty else { return nil }
        return SearchResult(
            bvid: bvid,
            title: stripTags(o["title"] as? String ?? ""),
            author: stripTags(o["author"] as? String ?? ""),
            coverUrl: normalizeCover(o["pic"] as? String),
            durationSec: parseDuration(o["duration"] as? String),
            play: o["play"] as? Int64 ?? 0,
            description: stripTags(o["description"] as? String ?? ""),
            tag: stripTags(o["tag"] as? String ?? ""),
            typeId: o["typeid"] as? Int ?? 0,
            paid: (o["is_pay"] as? Int ?? 0) == 1
        )
    }

    private func stripTags(_ raw: String) -> String {
        var s = raw
        // 简单 HTML 标签去除
        while let range = s.range(of: "<[^>]*>", options: .regularExpression) {
            s.replaceSubrange(range, with: "")
        }
        let entities: [(String, String)] = [
            ("&quot;", "\""), ("&amp;", "&"), ("&lt;", "<"),
            ("&gt;", ">"), ("&#39;", "'"),
        ]
        for (entity, char) in entities {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func parseDuration(_ raw: String?) -> Int64? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        var total: Int64 = 0
        for p in parts {
            guard let v = Int64(p.trimmingCharacters(in: .whitespaces)) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    private func normalizeCover(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        let url = raw.hasPrefix("//") ? "https:\(raw)" : raw
        guard url.hasPrefix("http://") || url.hasPrefix("https://"),
              let host = URL(string: url)?.host, BiliSource.hostAllowed(host) else { return nil }
        return url
    }
}

// MARK: - 分类与过滤

struct BiliCategory: Sendable, Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let keywords: [String]
    let order: String
}

enum BiliCategories {
    static let ORDER_TOTALRANK = "totalrank"
    static let ORDER_CLICK = "click"
    static let ORDER_PUBDATE = "pubdate"

    static let ALL: [BiliCategory] = [
        BiliCategory(key: "hot", name: "热门推荐", keywords: ["有声小说"], order: ORDER_CLICK),
        BiliCategory(key: "radio", name: "广播剧", keywords: ["广播剧"], order: ORDER_TOTALRANK),
        BiliCategory(key: "pingshu", name: "评书相声", keywords: ["评书", "相声"], order: ORDER_TOTALRANK),
        BiliCategory(key: "mystery", name: "悬疑推理", keywords: ["悬疑推理有声小说"], order: ORDER_TOTALRANK),
        BiliCategory(key: "xuanhuan", name: "玄幻仙侠", keywords: ["玄幻仙侠有声小说"], order: ORDER_TOTALRANK),
        BiliCategory(key: "classic", name: "名著悦读", keywords: ["名著有声书"], order: ORDER_TOTALRANK),
    ]

    static func of(_ key: String) -> BiliCategory? {
        ALL.first { $0.key == key }
    }
}

struct BiliOrderOption: Sendable { let code: String; let label: String }

enum BiliOrders {
    static let ALL: [BiliOrderOption] = [
        BiliOrderOption(code: BiliCategories.ORDER_TOTALRANK, label: "综合"),
        BiliOrderOption(code: BiliCategories.ORDER_CLICK, label: "播放量"),
        BiliOrderOption(code: BiliCategories.ORDER_PUBDATE, label: "最新"),
    ]

    static func labelOf(_ code: String) -> String {
        ALL.first { $0.code == code }?.label ?? code
    }
}

/// 有声内容识别规则
enum BiliAudioFilter {
    static let AUDIO_HINTS = [
        "有声小说", "有声书", "有声剧", "有声读物", "有声", "听书",
        "评书", "相声", "广播剧", "演播", "朗读", "诵读", "长书",
        "连播", "说书", "单口", "播讲", "多人剧", "小说剧",
    ]
    static let NOISE_HINTS = [
        "一口气看完", "漫推", "漫画", "解说", "讲解", "解读",
        "动画", "鬼畜", "混剪", "沙雕", "速看", "reaction",
        "预告", "游戏实况", "配音秀",
    ]
    static let GENRE_HINTS = [
        "评书", "相声", "广播剧", "听书", "演播", "朗读", "诵读",
        "长书", "连播", "说书", "单口", "播讲",
    ]

    static func isAudiobookItem(_ item: BiliSearchApi.SearchResult, keyword: String) -> Bool {
        let title = item.title
        let meta = "\(item.description) \(item.tag)"
        let duration = item.durationSec ?? 0
        if NOISE_HINTS.contains(where: { (title + meta).contains($0) }) { return false }
        if AUDIO_HINTS.contains(where: { title.contains($0) }) && duration >= 300 { return true }
        if item.typeId == 195 && duration >= 600 { return true }
        if AUDIO_HINTS.contains(where: { meta.contains($0) }) && duration >= 1800 { return true }
        if GENRE_HINTS.contains(where: { keyword.contains($0) }) && duration >= 1800 { return true }
        return false
    }
}
