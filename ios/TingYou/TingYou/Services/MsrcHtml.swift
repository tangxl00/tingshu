import Foundation

/// ting15 / ting08 多源宽容 HTML/JSON 解析（安卓 MsrcHtml.kt 的 Swift 移植）。
/// 任何字段缺失只置空，绝不让请求失败；脏数据降级而不是抛异常。
/// 纯函数、无 UI 依赖，可直接 XCTest。
enum MsrcHtml {

    // ---- 数据形态 ----

    struct MsrcSearchItem: Sendable, Equatable {
        let title: String
        let author: String?
        let teller: String?
        let cover: String?
        let detailPath: String
        let bookId: String
    }

    struct MsrcChapter: Sendable, Equatable {
        let page: Int
        let title: String
    }

    struct MsrcDetail: Sendable, Equatable {
        let title: String
        let author: String?
        let teller: String?
        let statusText: String
        let intro: String?
        let cover: String?
        let chapters: [MsrcChapter]
        var chapterCount: Int { chapters.count }
    }

    /// 两步 token 播放接口的宽容解析结果
    struct MsrcPlayResult: Sendable, Equatable {
        let status: Int
        let url: String?
        let detail: String?
        static func error(_ detail: String) -> MsrcPlayResult {
            MsrcPlayResult(status: 0, url: nil, detail: detail)
        }
    }

    /// 播放页 meta（两步 token 第一步）
    struct PlayPageMeta: Sendable, Equatable {
        let token: String
        let isPay: String
    }

    // ---- 正则（与安卓 MsrcHtml.kt / PC server.js 完全同构） ----

    private static let reMetaC = try! NSRegularExpression(pattern: #"<meta\s+name="_c"\s+content="([^"]*)""#)
    private static let reMetaP = try! NSRegularExpression(pattern: #"<meta\s+name="_p"\s+content="([^"]*)""#)
    private static let reAuthor = try! NSRegularExpression(pattern: #"作者：(?:<[^>]+>)*([^<]*)"#)
    private static let reTeller = try! NSRegularExpression(pattern: #"播音：(?:<[^>]+>)*([^<]*)"#)
    private static let reStatus = try! NSRegularExpression(pattern: #"状态：(?:<[^>]+>)*([^<]*)"#)

    private static let reItem15 = try! NSRegularExpression(
        pattern: #"<a\s+href="(/[a-z0-9]+/\d+\.html)"[^>]*>\s*<dl>\s*<dt>\s*<img[^>]+src="([^"]+)"[\s\S]*?<h3[^>]*>([\s\S]*?)</h3>([\s\S]*?)</dd>"#)
    private static let reItem08 = try! NSRegularExpression(
        pattern: #"<li>\s*<div class="img">\s*<a href="(/[a-z0-9]+/\d+\.html)"[^>]*>\s*<img[^>]+src="([^"]+)"[\s\S]*?<h4[^>]*>\s*<a[^>]*>([\s\S]*?)</a>\s*</h4>([\s\S]*?)</div>\s*</li>"#)

    private static let reChapLink = try! NSRegularExpression(
        pattern: #"href="(/[a-z0-9]+/(\d+)/0-(\d+)\.html)"[^>]*>([^<]*)"#)
    private static let reCover = try! NSRegularExpression(pattern: #"class="bimg">\s*<img[^>]+src="([^"]+)""#)
    private static let reH1 = try! NSRegularExpression(pattern: #"<h1[^>]*>([^<]*)</h1>"#)
    private static let reIntro = try! NSRegularExpression(pattern: #"class="intro">\s*<p>([\s\S]*?)</p>"#)
    private static let reTag = try! NSRegularExpression(pattern: #"<[^>]*>"#)

    // ---- 工具 ----

    /// encodeURI 语义（路径段）：表单语义空格→+ 需还原为 %20。
    /// 白名单必须是 ASCII 字母数字 + `-_.!~*'()+`：
    /// `CharacterSet.alphanumerics` 包含全部 Unicode 字母，中文关键词会原样透传，
    /// 拼出的搜索 URL 在服务端 400 → 搜索失败（安卓 encodeUriComponent 语义同为 ASCII）。
    static let uriComponentAllowed: CharacterSet = {
        var allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()+")
        return allowed
    }()

    static func encodeUriComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? s
    }

    private static func reSub(_ re: NSRegularExpression, _ s: String) -> String {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return "" }
        return String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ s: String) -> String {
        let out = reTag.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                                 withTemplate: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ---- build 21 · 反馈 2（Bug B）：HTML 实体解码 ----

    // build 36 返修（CI #4）：实体解码由 NSString + NSRegularExpression.enumerateMatches
    // + NSRange 互操作改为 Swift Regex（纯 Swift String.Range，deployment target 17 支持）。
    // 原实现静态自洽、沙箱静态审不出逻辑毛病，但 NSString 下标 / NSRange 换算是唯一
    // 的 Foundation 版本敏感面——CI Xcode 26.3 两轮 0.211s/0.251s 确定性失败（沙箱无
    // Swift 工具链无法本地复现，不猜具体行为差异，直接消除敏感面）。匹配语义与原
    // NSRegularExpression 完全一致：非重叠、最左优先、贪心；单层替换、先数字后命名、
    // 未识别实体原样保留的口径全部不变。
    private static let reNumericEntity = /&#(x[0-9A-Fa-f]+|\d+);/
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…",
        "middot": "·", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
    ]
    private static let reNamedEntity = /&(amp|lt|gt|quot|apos|nbsp|mdash|ndash|hellip|middot|ldquo|rdquo|lsquo|rsquo);/

    /// HTML 实体还原：命名实体（&amp; &quot; &nbsp; 等 14 个常用集）+
    /// 十六进制 &#x4E2D; 与十进制 &#20013; 数字实体。
    /// 只做一层替换（`&amp;#x4E2D;` 解为字面 `&#x4E2D;`，与浏览器行为一致）。
    /// 未识别实体原样保留。纯函数可直接 XCTest。
    static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        // 先数字后命名：&amp;#x4E2D; 解为字面 &#x4E2D;（数字先跑不会再碰新解出的实体）
        return decodeNamedEntities(in: decodeNumericEntities(in: s))
    }

    /// 命名实体解码：单次扫描 + 从后往前替换（&amp; 解出的 & 不会被二次解码）。
    private static func decodeNamedEntities(in s: String) -> String {
        var result = s
        let matches = reNamedEntity.matches(in: result)
        guard !matches.isEmpty else { return s }
        for m in matches.reversed() {
            guard let value = namedEntities[String(m.output.1)] else { continue }
            result.replaceSubrange(m.range, with: value)
        }
        return result
    }

    /// 数字实体解码：&#x4E2D; / &#20013; → 对应 Unicode 字符。
    /// 单次扫描收集后从后往前替换，避免下标漂移。
    private static func decodeNumericEntities(in s: String) -> String {
        var result = s
        let matches = reNumericEntity.matches(in: result)
        guard !matches.isEmpty else { return s }
        for m in matches.reversed() {
            let body = String(m.output.1)
            var code: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                code = UInt32(body.dropFirst(), radix: 16)
            } else {
                code = UInt32(body)
            }
            guard let code, let scalar = Unicode.Scalar(code) else { continue }
            result.replaceSubrange(m.range, with: String(Character(scalar)))
        }
        return result
    }

    static func sectionBetween(_ html: String, _ start: String, _ end: String) -> String {
        guard let startRange = html.range(of: start) else { return "" }
        var seg = String(html[startRange.lowerBound...])
        if let endIdx = seg.range(of: end), endIdx.lowerBound > seg.startIndex {
            if endIdx.lowerBound < seg.endIndex {
                seg = String(seg[..<endIdx.lowerBound])
            }
        }
        return seg
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String {
        guard let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }

    // ---- 搜索结果解析 ----

    static func parseSearch(cfg: SourceRegistry.MsrcSourceConfig, html: String) -> [MsrcSearchItem] {
        let seg = sectionBetween(html, cfg.searchStart, cfg.searchEnd)
        let re = cfg.searchPOST ? reItem08 : reItem15
        var items: [MsrcSearchItem] = []
        var seen = Set<String>()
        let ns = seg as NSString
        re.enumerateMatches(in: seg, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            let path = group(m, 1, in: seg)
            if path.isEmpty || !seen.insert(path).inserted { return }
            let cover = group(m, 2, in: seg)
            // build 21 · 反馈 2（Bug B）：标题/作者/播音出口统一做 HTML 实体还原
            let title = decodeHTMLEntities(stripTags(group(m, 3, in: seg)))
            let dd = group(m, 4, in: seg)
            let parts = path.split(separator: "/").map(String.init)
            let bookId = parts.count == 2 ? parts[1].replacingOccurrences(of: ".html", with: "") : ""
            let author = decodeHTMLEntities(stripTags(reSub(reAuthor, dd)))
            let teller = decodeHTMLEntities(stripTags(reSub(reTeller, dd)))
            items.append(MsrcSearchItem(
                title: title,
                author: author.isEmpty ? nil : author,
                teller: teller.isEmpty ? nil : teller,
                cover: cover.isEmpty ? nil : cover,
                detailPath: path,
                bookId: bookId
            ))
        }
        return items
    }

    // ---- 详情页解析 ----

    static func parseDetail(_ html: String) -> MsrcDetail {
        var head = sectionBetween(html, "class=\"book\"", "class=\"playlist\"")
        if head.isEmpty { head = sectionBetween(html, "class=\"bookinfo\"", "class=\"playlist\"") }
        let coverRaw = reSub(reCover, head)
        let title = reSub(reH1, head).replacingOccurrences(of: "有声小说", with: "")
        let authorRaw = stripTags(reSub(reAuthor, head))
        let tellerRaw = stripTags(reSub(reTeller, head))
        let statusText = stripTags(reSub(reStatus, head))
        let introRaw = stripTags(reSub(reIntro, html))

        let seg = sectionBetween(html, "class=\"plist\"", "</section>")
        var seen = Set<Int>()
        var chapters: [MsrcChapter] = []
        let nsSeg = seg as NSString
        reChapLink.enumerateMatches(in: seg, range: NSRange(location: 0, length: nsSeg.length)) { m, _, _ in
            guard let m = m else { return }
            guard let page = Int(group(m, 3, in: seg)) else { return }
            if page < 1 || !seen.insert(page).inserted { return }
            chapters.append(MsrcChapter(page: page, title: group(m, 4, in: seg).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        chapters.sort { $0.page < $1.page }
        return MsrcDetail(
            title: title,
            author: authorRaw.isEmpty ? nil : authorRaw,
            teller: tellerRaw.isEmpty ? nil : tellerRaw,
            statusText: statusText,
            intro: introRaw.isEmpty ? nil : introRaw,
            cover: coverRaw.isEmpty ? nil : coverRaw,
            chapters: chapters
        )
    }

    // ---- 播放页 meta 解析（两步 token 第一步） ----

    /// 刮播放页 meta：_c（token，必需）与 _p（isPay，缺省 "0"）
    static func parsePlayPage(_ html: String) -> PlayPageMeta? {
        let token = reSub(reMetaC, html)
        if token.isEmpty { return nil }
        var isPay = reSub(reMetaP, html)
        if isPay.isEmpty { isPay = "0" }
        return PlayPageMeta(token: token, isPay: isPay)
    }

    // ---- 音频接口响应解析（两步 token 第二步） ----

    /// 宽容解析 api-getneoplay 响应：剥 UTF-8 BOM；status 数字/字符串两形态；
    /// status=1 取 ourl || url，其余 status 原样透传（-1 付费 / -2 频控 / 0 异常）。
    static func parsePlayResponse(_ raw: String) -> MsrcPlayResult {
        var s = raw
        if !s.isEmpty && s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        let status = extractJsonStatus(s) ?? 0
        if status == 1 {
            let url = extractJsonStringField(s, "ourl")
                ?? extractJsonStringField(s, "url")
                ?? ""
            if url.isEmpty { return .error("播放地址为空") }
            return MsrcPlayResult(status: 1, url: url, detail: nil)
        }
        return MsrcPlayResult(status: status, url: nil, detail: nil)
    }

    /// status 字段兼容 "status":"1" 与 "status":1 两形态
    static func extractJsonStatus(_ json: String) -> Int? {
        if let strForm = extractJsonStringField(json, "status") {
            return Int(strForm) ?? Double(strForm).map(Int.init)
        }
        let numRe = try! NSRegularExpression(pattern: #""status"\s*:\s*(-?\d+)"#)
        guard let m = numRe.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let r = Range(m.range(at: 1), in: json) else { return nil }
        return Int(json[r])
    }

    /// 从（可能带 BOM / 脏空白）的 JSON 文本中提取字符串字段值（未命中或空串返回 nil，绝不抛）
    static func extractJsonStringField(_ json: String, _ field: String) -> String? {
        let pattern = #""\#(field)"\s*:\s*"((?:[^"\\]|\\.)*)""#
        let re = try! NSRegularExpression(pattern: pattern)
        guard let m = re.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let r = Range(m.range(at: 1), in: json) else { return nil }
        let v = String(json[r])
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\"", with: "\"")
        return v.isEmpty ? nil : v
    }
}
