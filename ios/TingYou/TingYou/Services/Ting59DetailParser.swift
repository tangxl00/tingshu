import Foundation

// build 29 · 59听书网详情页解析器（fixtures/detail.html 实测结构）。
// 页面结构（/mp3/{书ID}.html）：
// - 元数据区 div.playbox：img.conbigimg（封面）、ul > h2 > a[title]（书名）、
//   li > div > b 标签行——「播音」「作者」「小说类型」「更新时间」「更新状态」；
//   「播放人气」span#hit 为 JS 异步加载占位，静态解析拿不到——popularity 留 null；
// - 章节列表：第一个非 intro 的 div.numlist.border 内 li > a，
//   href /play/{书ID}-0-{序号}.html（0 基）；
// - 简介：div.numlist.border.intro > ul.introbox 文本节点。

enum Ting59DetailParser {

    private static let chapterHrefRe = try! NSRegularExpression(
        pattern: #"/play/(\d{1,12})-(\d{1,4})-(\d{1,5})\.html"#,
        options: []
    )

    static func parse(bookId: String, html: String) throws -> Ting59Adapter.Ting59BookDetail {
        // 书名
        guard let title = extractTitle(html: html), !title.isEmpty else {
            throw URLError(.badServerResponse)
        }

        // 元数据
        var narrator: String? = nil
        var author: String? = nil
        var category: String? = nil
        var updateTime: String? = nil
        var status: String? = nil

        var searchPos = html.startIndex
        while let bStart = html[searchPos...].range(of: "<b>") {
            guard let bEnd = html[bStart.upperBound...].range(of: "</b>") else { break }
            let label = String(html[bStart.upperBound..<bEnd.lowerBound])
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .filter { !$0.isWhitespace }
            let afterB = String(html[bEnd.upperBound...])
            guard let divEnd = afterB.range(of: "</div>") else { break }
            let divContent = String(afterB[..<divEnd.lowerBound])

            if label.hasPrefix("播音") {
                narrator = extractTagText(html: divContent, tag: "a")
                    ?? divContent.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
            } else if label.hasPrefix("作者") {
                author = extractTagText(html: divContent, tag: "a")
                    ?? divContent.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
            } else if label.hasPrefix("小说类型") {
                category = divContent.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            } else if label.hasPrefix("更新时间") {
                updateTime = divContent.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            } else if label.hasPrefix("更新状态") {
                status = divContent.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            searchPos = bEnd.upperBound
        }

        // 封面
        let coverUrl = extractCoverUrl(html: html)

        // 章节列表：第一个非 intro 的 div.numlist.border
        let chapters = extractChapters(html: html, bookId: bookId)

        // 简介
        let description = extractIntro(html: html)

        let book = Ting59Adapter.Ting59SearchItem(
            id: bookId,
            title: title,
            author: author?.isEmpty == false ? author : nil,
            narrator: narrator?.isEmpty == false ? narrator : nil,
            category: category?.isEmpty == false ? category : nil,
            updateTime: updateTime?.isEmpty == false ? updateTime : nil,
            detailUrl: "/mp3/\(bookId).html"
        )

        return Ting59Adapter.Ting59BookDetail(
            book: book,
            chapters: chapters,
            description: description
        )
    }

    // MARK: - 提取辅助

    private static func extractTitle(html: String) -> String? {
        // div.playbox > ul > h2 > a[title]
        let pattern = #"<div class=\"playbox\"[^>]*>.*?<ul>.*?<h2>.*?<a[^>]*title=\"([^\"]+)\""#
        let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(html.startIndex..., in: html)
        if let match = re.firstMatch(in: html, options: [], range: range),
           let r = Range(match.range(at: 1), in: html) {
            return String(html[r]).trimmingCharacters(in: .whitespaces)
        }
        // fallback: div.playbox ul h2 a 文本
        if let h2Start = html.range(of: "<h2>"), let h2End = html[h2Start.upperBound...].range(of: "</h2>") {
            let h2Content = String(html[h2Start.upperBound..<h2End.lowerBound])
            return extractTagText(html: h2Content, tag: "a")
        }
        return nil
    }

    private static func extractCoverUrl(html: String) -> String? {
        // img.conbigimg[src]
        let pattern = #"<img[^>]*class=\"conbigimg\"[^>]*src=\"([^\"]+)\""#
        let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(html.startIndex..., in: html)
        if let match = re.firstMatch(in: html, options: [], range: range),
           let r = Range(match.range(at: 1), in: html) {
            let src = String(html[r]).trimmingCharacters(in: .whitespaces)
            return src.isEmpty ? nil : src
        }
        return nil
    }

    private static func extractChapters(html: String, bookId: String) -> [Ting59Adapter.Ting59Chapter] {
        // 定位第一个非 intro 的 div.numlist.border
        var searchPos = html.startIndex
        var chapterBox: String? = nil
        while let boxStart = html[searchPos...].range(of: "<div class=\"numlist border\"") {
            let afterStart = String(html[boxStart.lowerBound...])
            guard let boxEnd = afterStart.range(of: "</div>") else { break }
            let box = String(afterStart[..<boxEnd.upperBound])
            if !box.contains("intro") {
                chapterBox = box
                break
            }
            searchPos = html.index(boxStart.lowerBound, offsetBy: 1)
        }
        guard let box = chapterBox else { return [] }

        var chapters: [Ting59Adapter.Ting59Chapter] = []
        var liSearch = box.startIndex
        while let aStart = box[liSearch...].range(of: "<a ") {
            guard let aEnd = box[aStart.upperBound...].range(of: "</a>") else { break }
            let aTag = String(box[aStart.lowerBound..<aEnd.upperBound])
            let range = NSRange(aTag.startIndex..., in: aTag)
            guard let match = chapterHrefRe.firstMatch(in: aTag, options: [], range: range),
                  let hrefBookIdRange = Range(match.range(at: 1), in: aTag),
                  String(aTag[hrefBookIdRange]) == bookId,
                  let indexRange = Range(match.range(at: 3), in: aTag),
                  let index = Int(aTag[indexRange]) else {
                liSearch = aEnd.upperBound
                continue
            }
            let name = extractTagText(html: aTag, tag: "a") ?? "第\(index + 1)集"
            chapters.append(Ting59Adapter.Ting59Chapter(index: index, title: name))
            liSearch = aEnd.upperBound
        }
        return chapters.sorted { $0.index < $1.index }
    }

    private static func extractIntro(html: String) -> String? {
        // div.numlist.border.intro > ul.introbox
        guard let introStart = html.range(of: "<div class=\"numlist border intro\"") else { return nil }
        let afterStart = String(html[introStart.lowerBound...])
        guard let introEnd = afterStart.range(of: "</div>") else { return nil }
        let introBox = String(afterStart[..<introEnd.upperBound])
        guard let ulStart = introBox.range(of: "<ul class=\"introbox\"") else { return nil }
        let afterUl = String(introBox[ulStart.upperBound...])
        guard let ulEnd = afterUl.range(of: "</ul>") else { return nil }
        let content = String(afterUl[..<ulEnd.lowerBound])
            .replacingOccurrences(of: "<script>.*?</script>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
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
