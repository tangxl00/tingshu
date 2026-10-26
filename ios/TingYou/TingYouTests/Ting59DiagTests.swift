import XCTest
@testable import TingYou

// TEMPORARY diagnostic file for build 37 Ting59 list-parser CI failures.
// Narrow-slice probes with prints; to be removed once root cause is fixed.
// Ordered so that safe probes (Diag0-Diag2, no production code) run before
// production parseSearch calls, in case a production `try!` traps.
final class Ting59DiagTests: XCTestCase {

    private static let bomFixture = "\u{FEFF}<div class=\"clist sear_height\"><ul>"
        + "<li><a href=\"/mp3/19745.html\" title=\"测试书\"><img src=\"https://img.ting59.com/19745.jpg\"/></a>"
        + "<dl><dd><a href=\"/mp3/19745.html\" title=\"测试书\"><b>测试书</b></a>"
        + "<p>作者：某作者</p><p>播音：小D</p></dd></dl></li>"
        + "</ul><div class=\"page\">共1条 <a href=\"/search.php?wd=%E4%B9%A6&amp;page=2\">下一页</a></div></div>"

    private static let plainFixture = "<div class=\"clist\"><ul><li><a href=\"/mp3/123.html\" title=\"分类书\"><b>分类书</b></a></li></ul>"
        + "<div class=\"page\">共1条</div></div>"

    private static let singleLineFixture = "<div class=\"clist sear_height\"><ul><li><a href=\"/mp3/19745.html\" title=\"测试书\"><img src=\"https://img.ting59.com/19745.jpg\"/></a><dl><dd><a href=\"/mp3/19745.html\" title=\"测试书\"><b>测试书</b></a><p>作者：某作者</p><p>播音：小D</p></dd></dl></li></ul><div class=\"page\">共1条 <a href=\"/search.php?wd=x&amp;page=2\">下一页</a></div></div>"

    // MARK: - Diag0 · raw-string escaped-quote regex probe (replica of production extractAttr pattern)

    func testDiag0EscapedQuoteRegexProbe() {
        let attr = "title"
        let pattern = #"\#(attr)=\"([^\"]+)\""#
        print("DIAG0 pattern=[\(pattern)] bytes=\(Array(pattern.utf8))")
        do {
            let re = try NSRegularExpression(pattern: pattern, options: [])
            let text = "<a title=\"测试书\"><b>测试书</b></a>"
            let range = NSRange(text.startIndex..., in: text)
            if let m = re.firstMatch(in: text, options: [], range: range),
               let vr = Range(m.range(at: 2), in: text) {
                print("DIAG0 MATCH value=[\(String(text[vr]))]")
            } else {
                print("DIAG0 NO MATCH")
            }
        } catch {
            print("DIAG0 REGEX ERROR: \(error)")
        }
        // 对照：无反斜杠引号的等价 pattern
        do {
            let re = try NSRegularExpression(pattern: "title=\"([^\"]+)\"", options: [])
            let text = "<a title=\"测试书\"><b>测试书</b></a>"
            let range = NSRange(text.startIndex..., in: text)
            if let m = re.firstMatch(in: text, options: [], range: range),
               let vr = Range(m.range(at: 2), in: text) {
                print("DIAG0 PLAIN-QUOTE MATCH value=[\(String(text[vr]))]")
            } else {
                print("DIAG0 PLAIN-QUOTE NO MATCH")
            }
        } catch {
            print("DIAG0 PLAIN-QUOTE REGEX ERROR: \(error)")
        }
    }

    // MARK: - Diag1 · local replica of findClistStart

    private func localFindClistStart(_ html: String) -> Range<String.Index>? {
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

    private func localExtractListItems(_ html: String) -> [String] {
        var items: [String] = []
        guard let clistStart = localFindClistStart(html) else { return items }
        let clistSection = String(html[clistStart.lowerBound...])
        guard let ulStart = clistSection.range(of: "<ul>") else { return items }
        let ulSection = String(clistSection[ulStart.lowerBound...])
        guard let ulEnd = ulSection.range(of: "</ul>") else { return items }
        let ulContent = String(ulSection[..<ulEnd.upperBound])
        var searchStart = ulContent.startIndex
        while let liStart = ulContent[searchStart...].range(of: "<li") {
            let afterLi = ulContent[liStart.lowerBound...]
            guard let liEnd = afterLi.range(of: "</li>") else { break }
            items.append(String(ulContent[liStart.lowerBound..<liEnd.upperBound]))
            searchStart = liEnd.upperBound
        }
        return items
    }

    func testDiag1LocalFindClistStart() {
        let f1 = Self.bomFixture
        let f1s = f1.hasPrefix("\u{FEFF}") ? String(f1.dropFirst()) : f1
        print("DIAG1 bom(stripped) found=\(localFindClistStart(f1s) != nil)")
        print("DIAG1 bom(with-BOM) found=\(localFindClistStart(f1) != nil)")
        print("DIAG1 plain found=\(localFindClistStart(Self.plainFixture) != nil)")
        let f3 = "<div class=\"clist2\"><ul><li>x</li></ul></div>"
        print("DIAG1 clist2 found=\(localFindClistStart(f3) != nil)")
    }

    // MARK: - Diag2 · local pipeline replica (slice + bookIdRe) with stage prints

    func testDiag2LocalPipelineReplica() {
        let cases: [(String, String)] = [
            ("bom", Self.bomFixture),
            ("plain", Self.plainFixture),
            ("singleLine", Self.singleLineFixture),
        ]
        for (name, raw) in cases {
            let h = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
            if let cs = localFindClistStart(h) {
                print("DIAG2 \(name): clistFound offset=\(h.distance(from: h.startIndex, to: cs.lowerBound))")
            } else {
                print("DIAG2 \(name): clistFound=NO")
            }
            let items = localExtractListItems(h)
            print("DIAG2 \(name): items=\(items.count)")
            for (i, item) in items.enumerated() {
                print("DIAG2 \(name) item[\(i)]=[\(item)]")
                do {
                    let re = try NSRegularExpression(pattern: #"/mp3/(\d{1,12})\.html"#, options: [])
                    let range = NSRange(item.startIndex..., in: item)
                    if let m = re.firstMatch(in: item, options: [], range: range),
                       let vr = Range(m.range(at: 1), in: item) {
                        print("DIAG2 \(name) id=[\(String(item[vr]))]")
                    } else {
                        print("DIAG2 \(name): bookIdRe NO MATCH")
                    }
                } catch {
                    print("DIAG2 \(name): bookIdRe ERROR: \(error)")
                }
            }
        }
    }

    // MARK: - Diag3-6 · production parser calls with result prints

    private func dumpResult(_ tag: String, _ result: Ting59ListParsers.Ting59SearchResult) {
        print("DIAG\(tag): count=\(result.list.count) hasMore=\(result.hasMore) total=\(result.total)")
        for item in result.list {
            print("DIAG\(tag) item id=[\(item.id)] title=[\(item.title)] author=[\(item.author ?? "nil")] narrator=[\(item.narrator ?? "nil")] category=[\(item.category ?? "nil")] updateTime=[\(item.updateTime ?? "nil")] url=[\(item.detailUrl)]")
        }
    }

    func testDiag3ProductionParseSearchBom() {
        dumpResult("3", Ting59ListParsers.parseSearch(doc: Self.bomFixture))
    }

    func testDiag4ProductionParseSearchPlain() {
        dumpResult("4", Ting59ListParsers.parseSearch(doc: Self.plainFixture))
    }

    func testDiag5ProductionParseSearchSingleLineNoBom() {
        dumpResult("5", Ting59ListParsers.parseSearch(doc: Self.singleLineFixture))
    }

    func testDiag6ProductionParseCategory() {
        let r = Ting59ListParsers.parseCategory(doc: Self.bomFixture)
        print("DIAG6: books=\(r.books.count) hasMore=\(r.hasMore)")
        for b in r.books {
            print("DIAG6 book id=[\(b.id)] title=[\(b.title)] author=[\(b.author ?? "nil")]")
        }
    }
}
