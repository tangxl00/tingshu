import Foundation

// build 29 · 59听书网列表页解析器（搜索页 + 分类页共用）。
// 页面结构（2026-10-22 实地核实 fixtures/search.html、category.html）：
// - 主列表区：div.clist > ul > li（搜索页 div 带 sear_height 类）；
//   条目有两种格式：
//   1. 完整格式：li > a[href=/mp3/{id}.html] > img（封面）+ li dl dd > a[href=/mp3/…][title] > b（书名）
//      + p 作者：/类型：/播音：/时间：；
//   2. 紧凑格式（分类页人气榜 li.line）：li > a[title][href=/mp3/…]（书名）+ span（人气数字），
//      无封面、无播音/作者；
// - 分页：div.clist > div.page，「下一页」锚点存在 = hasMore。

enum Ting59ListParsers {

    struct Ting59SearchResult: Sendable {
        let list: [Ting59Adapter.Ting59SearchItem]
        let hasMore: Bool
        let total: Int
    }

    struct Ting59CategoryResult: Sendable {
        let books: [Ting59Adapter.Ting59SearchItem]
        let hasMore: Bool
    }

    private static let bookIdRe = try! NSRegularExpression(
        pattern: #"/mp3/(\d{1,12})\.html"#,
        options: []
    )

    static func parseSearch(doc: String) -> Ting59SearchResult {
        let html = stripBom(doc)
        let items = extractListItems(html: html)
        let books = items.compactMap { parseItem(html: $0) }
        return Ting59SearchResult(
            list: books,
            hasMore: hasMore(html: html),
            total: totalFromPage(html: html)
        )
    }

    static func parseCategory(doc: String) -> Ting59CategoryResult {
        let html = stripBom(doc)
        let items = extractListItems(html: html)
        let books = items.compactMap { parseItem(html: $0) }
        return Ting59CategoryResult(books: books, hasMore: hasMore(html: html))
    }

    /// build 37 · 反馈 4：站点响应带 UTF-8 BOM（EF BB BF），整页解析前剥除；
    /// 字符串 range 查找本身不受 BOM 影响，此为防御性剥除（BOM 出现在页首时
    /// 保证首标签定位与 fixture 断言行为一致）。
    private static func stripBom(_ s: String) -> String {
        s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }

    // MARK: - 分页

    private static func hasMore(html: String) -> Bool {
        // 查找 div.page 中的「下一页」锚点
        guard let pageRange = html.range(of: "<div class=\"page\"") else { return false }
        let pageSection = String(html[pageRange.lowerBound...])
        guard let pageEnd = pageSection.range(of: "</div>") else { return false }
        let pageContent = String(pageSection[..<pageEnd.upperBound])
        return pageContent.contains("下一页")
    }

    private static func totalFromPage(html: String) -> Int {
        guard let pageRange = html.range(of: "<div class=\"page\"") else { return -1 }
        let pageSection = String(html[pageRange.lowerBound...])
        guard let pageEnd = pageSection.range(of: "</div>") else { return -1 }
        let pageContent = String(pageSection[..<pageEnd.upperBound])
        let totalRe = try! NSRegularExpression(pattern: #"共(\d+)条"#, options: [])
        let range = NSRange(pageContent.startIndex..., in: pageContent)
        guard let match = totalRe.firstMatch(in: pageContent, options: [], range: range),
              let numRange = Range(match.range(at: 1), in: pageContent),
              let total = Int(pageContent[numRange]) else { return -1 }
        return total
    }

    // MARK: - 列表条目提取

    /// 定位 clist 容器起始：匹配 `<div class="clist` 前缀后，校验下一字符为
    /// 引号 / 空格 / `>` 之一（分别对应 `class="clist"`、`class="clist sear_height"`
    /// 与无引号写法）；其他字符（如 clist2 的数字）视为同前缀类名，继续向后找。
    private static func findClistStart(_ html: String) -> Range<String.Index>? {
        var searchStart = html.startIndex
        while let r = html[searchStart...].range(of: "<div class=\"clist") {
            let after = r.upperBound
            guard after < html.endIndex else { return nil }
            let next = html[after]
            if next == "\"" || next == " " || next == ">" { return r }
            searchStart = after
        }
        return nil
    }

    private static func extractListItems(html: String) -> [String] {
        var items: [String] = []
        // 定位 div.clist > ul 内的 li 条目
        // build 37 · 反馈 4：真实搜索页形态为 <div class="clist sear_height">、
        // 分类页为 <div class="clist">——旧实现精确匹配 `"clist"`（后紧跟引号）在
        // 搜索页永远落空（搜索无结果的直接根因）。改为前缀匹配 + 边界校验，
        // 两种形态都命中，且不误伤 clistX 之类同前缀类名。
        guard let clistStart = findClistStart(html) else { return items }
        let clistSection = String(html[clistStart.lowerBound...])
        guard let ulStart = clistSection.range(of: "<ul>") else { return items }
        let ulSection = String(clistSection[ulStart.lowerBound...])
        guard let ulEnd = ulSection.range(of: "</ul>") else { return items }
        let ulContent = String(ulSection[..<ulEnd.upperBound])

        var searchStart = ulContent.startIndex
        while let liStart = ulContent[searchStart...].range(of: "<li") {
            let afterLi = ulContent[liStart.lowerBound...]
            guard let liEnd = afterLi.range(of: "</li>") else { break }
            let item = String(ulContent[liStart.lowerBound..<liEnd.upperBound])
            items.append(item)
            searchStart = liEnd.upperBound
        }
        return items
    }

    // MARK: - 单条目解析

    private static func parseItem(html: String) -> Ting59Adapter.Ting59SearchItem? {
        // 提取书 ID：从 /mp3/{id}.html href
        let range = NSRange(html.startIndex..., in: html)
        guard let match = bookIdRe.firstMatch(in: html, options: [], range: range),
              let idRange = Range(match.range(at: 1), in: html) else { return nil }
        let id = String(html[idRange])
        guard !id.isEmpty else { return nil }

        // 书名：优先 dl dd a[title]，其次 a[title]，然后 p b a，最后 a 文本
        var title: String? = nil
        // dl dd a
        if let ddStart = html.range(of: "<dd>"), let ddEnd = html[ddStart.upperBound...].range(of: "</dd>") {
            let ddContent = String(html[ddStart.upperBound..<ddEnd.lowerBound])
            title = extractAttr(text: ddContent, attr: "title")
                ?? extractTagText(html: ddContent, tag: "b")
                ?? extractTagText(html: ddContent, tag: "a")
        }
        // a[title]
        if title == nil || title!.isEmpty {
            title = extractAttr(text: html, attr: "title")
        }
        // p b a
        if title == nil || title!.isEmpty {
            if let pStart = html.range(of: "<p>"), let pEnd = html[pStart.upperBound...].range(of: "</p>") {
                let pContent = String(html[pStart.upperBound..<pEnd.lowerBound])
                title = extractTagText(html: pContent, tag: "b")
                    ?? extractTagText(html: pContent, tag: "a")
            }
        }
        // fallback: 第一个 a 标签文本
        if title == nil || title!.isEmpty {
            title = extractTagText(html: html, tag: "a")
        }
        guard let finalTitle = title, !finalTitle.isEmpty else { return nil }

        // p 标签字段
        var author: String? = nil
        var narrator: String? = nil
        var category: String? = nil
        var updateTime: String? = nil

        var searchPos = html.startIndex
        while let pStart = html[searchPos...].range(of: "<p>") {
            guard let pEnd = html[pStart.upperBound...].range(of: "</p>") else { break }
            let pText = String(html[pStart.upperBound..<pEnd.lowerBound])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if pText.hasPrefix("作者：") {
                let val = String(pText.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                author = String(val.prefix(while: { $0 != "播" && $0 != "音" })).trimmingCharacters(in: .whitespaces)
            } else if pText.hasPrefix("类型：") {
                category = String(pText.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if pText.hasPrefix("播音：") {
                let val = String(pText.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                narrator = String(val.prefix(while: { $0 != "音" && $0 != "频" })).trimmingCharacters(in: .whitespaces)
            } else if pText.hasPrefix("时间：") {
                updateTime = String(pText.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            searchPos = pEnd.upperBound
        }

        return Ting59Adapter.Ting59SearchItem(
            id: id,
            title: finalTitle,
            author: author,
            narrator: narrator,
            category: category,
            updateTime: updateTime,
            detailUrl: "/mp3/\(id).html"
        )
    }

    // MARK: - HTML 辅助

    private static func extractAttr(text: String, attr: String) -> String? {
        // NOTE(build37): 此前用 raw string 插值构造 #"\#(attr)=\"([^\"]+)\""#，
        // 在 CI（Xcode 26.3 / iOS 26.2 SDK）上运行时触发 NSRegularExpression ObjC 异常；
        // 改为普通字符串拼接，产出无反斜杠转义的 pattern（引号非正则元字符，无需转义）。
        let pattern = attr + "=\"([^\"]+)\""
        let re = try! NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, options: [], range: range),
              let valRange = Range(match.range(at: 2), in: text) else { return nil }
        let val = String(text[valRange]).trimmingCharacters(in: .whitespaces)
        return val.isEmpty ? nil : val
    }

    private static func extractTagText(html: String, tag: String) -> String? {
        let open = "<\(tag)[^>]*>"
        let close = "</\(tag)>"
        let pattern = open + "([^<]*)" + close
        let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..., in: html)
        guard let match = re.firstMatch(in: html, options: [], range: range),
              let textRange = Range(match.range(at: 1), in: html) else { return nil }
        let text = String(html[textRange]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
