import XCTest
@testable import TingYou

final class ImportOrganizerTests: XCTestCase {

    func testNaturalSortChapter2Before10() {
        let names = ["第10集.mp3", "第2集.mp3", "第1集.mp3"]
        let sorted = ImportOrganizer.naturalSort(names)
        XCTAssertEqual(sorted, ["第1集.mp3", "第2集.mp3", "第10集.mp3"])
    }

    func testNaturalSortNumericComparison() {
        XCTAssertTrue(ImportOrganizer.naturalCompare("chap2.mp3", "chap10.mp3") < 0)
        XCTAssertTrue(ImportOrganizer.naturalCompare("chap10.mp3", "chap2.mp3") > 0)
        XCTAssertEqual(ImportOrganizer.naturalCompare("same.mp3", "same.mp3"), 0)
        XCTAssertTrue(ImportOrganizer.naturalCompare("a01.mp3", "a1.mp3") < 0)
        XCTAssertTrue(ImportOrganizer.naturalCompare("chapter.mp3", "chapter2.mp3") < 0)
    }

    func testNaturalSortMixedChineseNumbers() {
        let names = ["故事10.mp3", "故事3.mp3", "故事1.mp3", "故事2.mp3"]
        let sorted = ImportOrganizer.naturalSort(names)
        XCTAssertEqual(sorted, ["故事1.mp3", "故事2.mp3", "故事3.mp3", "故事10.mp3"])
    }

    func testChapterTitleRemovesExtension() {
        XCTAssertEqual(ImportOrganizer.chapterTitle("第01集.mp3"), "第01集")
        XCTAssertEqual(ImportOrganizer.chapterTitle("track.m4a"), "track")
        XCTAssertEqual(ImportOrganizer.chapterTitle("无扩展名"), "无扩展名")
    }

    func testSuggestBookTitleFromCommonPrefix() {
        let names = ["凡人修仙传 第01集.mp3", "凡人修仙传 第02集.mp3", "凡人修仙传 第10集.mp3"]
        XCTAssertEqual(ImportOrganizer.suggestBookTitle(names), "凡人修仙传")
    }

    func testSuggestBookTitleNoPrefixFallsBack() {
        let names = ["完全不同的名字.mp3", "另一个集数.mp3"]
        XCTAssertEqual(ImportOrganizer.suggestBookTitle(names), "完全不同的名字")
    }

    func testSuggestBookTitleSingleFile() {
        XCTAssertEqual(ImportOrganizer.suggestBookTitle(["孤本.flac"]), "孤本")
    }

    func testParseDirectLinksAcceptsHttpsDeduplicates() {
        let text = """
            https://a.example.com/ch1.mp3
            https://a.example.com/ch1.mp3
              https://b.example.com/ch2.m4a

            https://c.example.com/ch3.flac
        """
        let result = ImportOrganizer.parseDirectLinks(text)
        XCTAssertTrue(result.isOK)
        let links = result.links!
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0].url, "https://a.example.com/ch1.mp3")
        XCTAssertEqual(links[1].url, "https://b.example.com/ch2.m4a")
        XCTAssertEqual(links[2].url, "https://c.example.com/ch3.flac")
    }

    func testParseDirectLinksRejectsHttpAndPlainText() {
        let result = ImportOrganizer.parseDirectLinks("http://a.com/ch1.mp3\n不是链接\nhttps://ok.com/ch2.mp3")
        XCTAssertFalse(result.isOK)
        XCTAssertEqual(result.badLines, ["http://a.com/ch1.mp3", "不是链接"])
    }

    func testParseDirectLinksCaseInsensitiveScheme() {
        let result = ImportOrganizer.parseDirectLinks("HTTPS://A.example.com/ch1.mp3")
        XCTAssertTrue(result.isOK)
    }

    func testParseM3uExtinfTitles() {
        let text = """
            #EXTM3U
            #EXTINF:300,第01集 三体
            https://cdn.example.com/01.mp3
            #EXTINF:-1,第02集 黑暗森林
            https://cdn.example.com/02.mp3
            https://cdn.example.com/03.mp3
        """
        let result = ImportOrganizer.parseM3u(text)
        XCTAssertTrue(result.isOK)
        let links = result.links!
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0].title, "第01集 三体")
        XCTAssertEqual(links[1].title, "第02集 黑暗森林")
        XCTAssertNil(links[2].title)
    }

    func testParseM3uRejectsHttpEntries() {
        let text = "#EXTM3U\nhttps://ok.example.com/1.mp3\nhttp://bad.example.com/2.mp3"
        let result = ImportOrganizer.parseM3u(text)
        XCTAssertFalse(result.isOK)
        XCTAssertEqual(result.badLines, ["http://bad.example.com/2.mp3"])
    }

    func testUrlTools() {
        XCTAssertEqual(ImportOrganizer.titleFromUrl("https://a.b/c/d/第1集.mp3"), "第1集.mp3")
        XCTAssertNil(ImportOrganizer.titleFromUrl("https://a.b/"))
        XCTAssertTrue(ImportOrganizer.isM3uUrl("https://a.b/list.M3U"))
        XCTAssertTrue(ImportOrganizer.isM3uUrl("https://a.b/list.m3u8"))
        XCTAssertFalse(ImportOrganizer.isM3uUrl("https://a.b/list.mp3"))
        XCTAssertEqual(ImportOrganizer.hostOf("https://CDN.Example.com/1.mp3"), "cdn.example.com")
        XCTAssertNil(ImportOrganizer.hostOf("不是链接"))
    }

    func testImportFormats() {
        XCTAssertTrue(ImportOrganizer.hasAudioExtension("a.MP3"))
        XCTAssertTrue(ImportOrganizer.hasAudioExtension("b.m4a"))
        XCTAssertFalse(ImportOrganizer.hasAudioExtension("c.txt"))
        XCTAssertFalse(ImportOrganizer.hasAudioExtension("noext"))
    }
}
