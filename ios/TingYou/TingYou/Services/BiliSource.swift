import Foundation

/// B站视频音轨音源常量（build 29 · 对齐 Android BiliSource.kt）
enum BiliSource {
    /// 对外源标识
    static let SRC = "bili"
    /// 导入书种类标识
    static let KIND = "bili"
    /// 章节占位 URI 协议头
    static let CHAPTER_SCHEME = "tingyou-bili"

    /// B站出站域后缀白名单
    static let HOST_SUFFIXES: [String] = [
        "bilibili.com",
        "b23.tv",
        "bilivideo.com",
        "biliapi.net",
        "akamaized.net",
        "hdslb.com",
    ]

    /// host 是否属于 B站域
    static func hostAllowed(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        return HOST_SUFFIXES.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// 付费/大会员/充电专属内容导入拒绝文案
    static let paidImportRejectMessage =
        "该视频为付费/大会员/充电专属内容，仅支持导入公开视频（未登录无法收听）。App 不提供任何绕过。"

    /// 构建 B站章节占位 URI
    static func buildChapterUri(bvid: String, cid: Int64) -> String {
        "\(CHAPTER_SCHEME)://audio?bvid=\(bvid)&cid=\(cid)"
    }

    /// 是否为 B站章节占位 URI
    static func isBiliChapterUri(_ uri: String) -> Bool {
        uri.hasPrefix("\(CHAPTER_SCHEME)://")
    }

    /// 解析章节占位 URI → (bvid, cid)
    static func parseChapterUri(_ uri: String) -> (bvid: String, cid: Int64)? {
        guard isBiliChapterUri(uri),
              let url = URL(string: uri),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let q = Dictionary(uniqueKeysWithValues: comps.queryItems?.compactMap { ($0.name, $0.value ?? "") } ?? [])
        guard let bvid = q["bvid"], !bvid.isEmpty,
              let cidStr = q["cid"],
              let cid = Int64(cidStr), cid > 0 else { return nil }
        return (bvid, cid)
    }
}

/// B站用户输入解析（build 29 · 纯逻辑）
enum BiliInputParser {
    enum Parsed {
        case video(bvid: String)
        case av(aid: Int64)
        case shortLink(url: String)
    }

    private static let bvRe = try! NSRegularExpression(pattern: "BV[0-9A-Za-z]{8,12}")
    private static let avRe = try! NSRegularExpression(pattern: "av([0-9]{1,15})", options: .caseInsensitive)

    static func parse(_ raw: String) -> Parsed? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // b23.tv 短链
        if s.contains("b23.tv") {
            let url = s.hasPrefix("http://") || s.hasPrefix("https://") ? s : "https://\(s)"
            guard let host = URL(string: url)?.host, BiliSource.hostAllowed(host) else { return nil }
            return .shortLink(url: url)
        }

        // http(s) 链接
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            guard let host = URL(string: s)?.host, BiliSource.hostAllowed(host) else { return nil }
            if let match = bvRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let range = Range(match.range, in: s) {
                return .video(bvid: String(s[range]))
            }
            if let match = avRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let range = Range(match.range(at: 1), in: s),
               let aid = Int64(s[range]) {
                return .av(aid: aid)
            }
            return nil
        }

        // 纯 BV 号
        if let match = bvRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let range = Range(match.range, in: s),
           range.lowerBound == s.startIndex, range.upperBound == s.endIndex {
            return .video(bvid: String(s[range]))
        }
        // 纯 av 号
        if let match = avRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let range = Range(match.range(at: 1), in: s),
           let aid = Int64(s[range]),
           range.lowerBound == s.startIndex, range.upperBound == s.endIndex {
            return .av(aid: aid)
        }
        return nil
    }
}
