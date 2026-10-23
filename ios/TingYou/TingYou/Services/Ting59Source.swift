import Foundation

// build 29 · 59听书网音源常量与纯字符串逻辑（无平台依赖，XCTest 直接覆盖）。
// 定位与边界（对齐 BiliSource 模式，合规硬约束）：
// - 只做站内公开书籍的在线流式收听：播放页解析 var now="..." 取音频直链交给
//   AVPlayer 播放，App 不存储、不缓存任何音频数据到磁盘；
// - 展示播音/作者/书名/站点名（59听书网）；
// - 站点为免费公开 HTML 站，无登录态、无付费内容、无绕过面。

enum Ting59Source {
    /// 对外源标识（占位 URI src 参数 / 收藏历史复合键 / SourceRouter 路由）
    static let SRC = "ting59"
    /// 导入书种类标识（imported_books.kind）
    static let KIND = "ting59"
    /// 59听书网章节占位 URI 协议头：真实直链不落库，播放时经 PlaybackRepository ting59 分支实时解析
    static let CHAPTER_SCHEME = "tingyou-ting59"

    /// 59听书网出站域后缀白名单
    static let HOST_SUFFIXES = [
        "ting59.com",
        "xmcdn.com",
    ]

    static func hostAllowed(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        return HOST_SUFFIXES.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// 构建 59听书网章节占位 URI（存库；播放时解析播放页 var now 取真实直链）。
    /// playIndex 为站点播放页 0 基序号：/play/{书ID}-0-{playIndex}.html = 第 playIndex+1 集。
    static func buildChapterUri(bookId: String, playIndex: Int) -> String {
        "\(CHAPTER_SCHEME)://audio?bookId=\(bookId)&playIndex=\(playIndex)"
    }

    static func isTing59ChapterUri(_ uri: String) -> Bool {
        uri.hasPrefix("\(CHAPTER_SCHEME)://")
    }

    /// 解析章节占位 URI → (bookId, playIndex 0 基)；非本格式返回 nil。
    static func parseChapterUri(_ uri: String) -> (bookId: String, playIndex: Int)? {
        guard isTing59ChapterUri(uri) else { return nil }
        guard let url = URL(string: uri),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary(uniqueKeysWithValues: comps.queryItems?.compactMap { qi in
            qi.value.map { (qi.name, $0) }
        } ?? [])
        guard let bookId = query["bookId"], !bookId.isEmpty, bookId.allSatisfy({ $0.isNumber }),
              let playIndexStr = query["playIndex"],
              let playIndex = Int(playIndexStr), playIndex >= 0 else { return nil }
        return (bookId, playIndex)
    }
}

// build 29 · 用户输入解析（纯逻辑）：支持
// - 59听书网书籍详情页完整链接（www.ting59.com/mp3/{书ID}.html，http/https 均可）；
// - m.ting59.com 手机版同路径链接。
enum Ting59InputParser {
    private static let bookUrlRe = try! NSRegularExpression(
        pattern: #"/mp3/(\d{1,12})\.html"#,
        options: []
    )

    static func parse(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
        guard let url = URL(string: s), let host = url.host else { return nil }
        guard Ting59Source.hostAllowed(host) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = bookUrlRe.firstMatch(in: s, options: [], range: range),
              let idRange = Range(match.range(at: 1), in: s) else { return nil }
        let id = String(s[idRange])
        guard !id.isEmpty else { return nil }
        return id
    }
}
