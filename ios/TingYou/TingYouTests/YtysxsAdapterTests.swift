import XCTest
@testable import TingYou

/// 悦听有声书适配器：反爬特征识别 + 搜索/详情/曲目解析黄金样本（P0-3 / P0-4）。
final class YtysxsAdapterTests: XCTestCase {

    // MARK: - 反爬识别（RE_ANTIBOT）

    func testIsAntibotDetectsAllKeywords() {
        XCTAssertTrue(YtysxsAdapter.isAntibot("<html><title>搜索驗證</title></html>"))
        XCTAssertTrue(YtysxsAdapter.isAntibot("<html><title>搜索验证</title></html>"))
        XCTAssertTrue(YtysxsAdapter.isAntibot("<div>安全检查，请稍候</div>"))
        XCTAssertTrue(YtysxsAdapter.isAntibot("<div>安全验证</div>"))
        XCTAssertTrue(YtysxsAdapter.isAntibot(#"<script src="cf-turnstile.js"></script>"#))
        XCTAssertTrue(YtysxsAdapter.isAntibot(#"<input name="be_captcha_token" value="x"/>"#))
    }

    func testIsAntibotNormalPage() {
        XCTAssertFalse(YtysxsAdapter.isAntibot("<html><h1>斗罗大陆</h1>正文</html>"))
        XCTAssertFalse(YtysxsAdapter.isAntibot(""))
    }

    // MARK: - 搜索结果解析

    private let searchHtml = """
    <html><body>
    <main>
    <article class="post"><a href="https://www.ytysxs.com/10086.html"><img src="c.jpg"/><h2 class="entry-title">三体</h2></a></article>
    <article class="post"><a href="https://www.ytysxs.com/10087.html"><h2>球状闪电</h2></a></article>
    <article class="post"><a href="https://www.ytysxs.com/10086.html"><h2>三体（重复）</h2></a></article>
    </main>
    </body></html>
    """

    func testParseSearchHtmlGolden() {
        let items = YtysxsAdapter.parseSearchHtml(searchHtml)
        XCTAssertEqual(items.count, 2, "同 bookId 的重复条目应去重")
        XCTAssertEqual(items[0].title, "三体")
        XCTAssertEqual(items[0].bookId, 10086)
        XCTAssertEqual(items[0].detailPath, "https://www.ytysxs.com/10086.html")
        XCTAssertEqual(items[1].bookId, 10087)
        XCTAssertEqual(items[1].title, "球状闪电")
    }

    func testParseSearchHtmlSkipsEntriesWithoutBookId() {
        let html = #"<article><a href="https://www.ytysxs.com/tag/san-ti"><h2>标签页</h2></a></article>"#
        XCTAssertTrue(YtysxsAdapter.parseSearchHtml(html).isEmpty, "非 /数字.html 链接不构成书目")
    }

    // MARK: - 详情解析

    private let detailHtml = """
    <html><head>
    <meta property="og:image" content="https://www.ytysxs.com/wp-content/uploads/cover.jpg"/>
    <meta property="og:description" content="刘慈欣科幻巨著"/>
    </head><body>
    <h1 class="entry-title">三体</h1>
    <div data-tracks-url="https://www.ytysxs.com/wp-json/audioigniter/v1/playlist/777?x=1"></div>
    <div data-tracks-url="https://www.ytysxs.com/wp-json/audioigniter/v1/playlist/778"></div>
    <div data-tracks-url="https://www.ytysxs.com/wp-json/audioigniter/v1/playlist/777"></div>
    </body></html>
    """

    func testParseDetailHtmlGolden() {
        let d = YtysxsAdapter.parseDetailHtml(detailHtml)
        XCTAssertEqual(d.title, "三体")
        XCTAssertEqual(d.cover, "https://www.ytysxs.com/wp-content/uploads/cover.jpg")
        XCTAssertEqual(d.intro, "刘慈欣科幻巨著")
        XCTAssertEqual(d.playlists.count, 2, "重复 pid 应去重")
        XCTAssertEqual(d.playlists[0].pid, 777)
        XCTAssertEqual(d.playlists[1].pid, 778)
    }

    func testParseDetailHtmlDegradesWhenEmpty() {
        let d = YtysxsAdapter.parseDetailHtml("<html><body></body></html>")
        XCTAssertEqual(d.title, "")
        XCTAssertNil(d.cover)
        XCTAssertNil(d.intro)
        XCTAssertTrue(d.playlists.isEmpty)
    }

    // MARK: - 曲目 JSON 解析

    private let tracksJson = """
    [
      {"title":"第01集","subtitle":"三体 I","audio":"https://mp3.ytysxs.top/1/001.mp3","cover":"https://www.ytysxs.com/c1.jpg"},
      {"title":"第02集","audio":"https://mp3.ytysxs.top/1/002.mp3"},
      {"title":"","audio":"https://mp3.ytysxs.top/1/003.mp3"},
      {"title":"无音频"},
      {"audio":"https://mp3.ytysxs.top/1/004.mp3"}
    ]
    """

    func testParseTracksJsonGolden() {
        let tracks = YtysxsAdapter.parseTracksJson(tracksJson)
        XCTAssertEqual(tracks.count, 2, "缺 title 或缺 audio 的条目应跳过")
        XCTAssertEqual(tracks[0].title, "第01集")
        XCTAssertEqual(tracks[0].subtitle, "三体 I")
        XCTAssertEqual(tracks[0].audio, "https://mp3.ytysxs.top/1/001.mp3")
        XCTAssertEqual(tracks[0].cover, "https://www.ytysxs.com/c1.jpg")
        XCTAssertEqual(tracks[1].title, "第02集")
        XCTAssertEqual(tracks[1].subtitle, "")
    }

    func testParseTracksJsonInvalidJsonReturnsEmpty() {
        XCTAssertTrue(YtysxsAdapter.parseTracksJson("not json").isEmpty)
        XCTAssertTrue(YtysxsAdapter.parseTracksJson("{}").isEmpty)
        XCTAssertTrue(YtysxsAdapter.parseTracksJson("").isEmpty)
    }

    // MARK: - 播放直链白名单自检

    func testPlayUrlWhitelistAllowsYtysxsAudioHost() throws {
        let chapter = YtysxsAdapter.YtysxsChapter(index: 1, title: "t", subtitle: "",
                                                   audioUrl: "https://mp3.ytysxs.top/1/001.mp3", coverUrl: "")
        let adapter = YtysxsAdapter(apiClient: APIClient(), cookieStore: nil)
        XCTAssertEqual(try adapter.playUrl(chapter: chapter), "https://mp3.ytysxs.top/1/001.mp3")
    }

    func testPlayUrlWhitelistRejectsForeignAndPlainHttp() {
        let adapter = YtysxsAdapter(apiClient: APIClient(), cookieStore: nil)
        let cases = [
            "https://evil.com/1.mp3",
            "http://mp3.ytysxs.top/1/001.mp3",
            "ftp://mp3.ytysxs.top/1.mp3",
            "",
        ]
        for url in cases {
            let chapter = YtysxsAdapter.YtysxsChapter(index: 1, title: "t", subtitle: "", audioUrl: url, coverUrl: "")
            XCTAssertThrowsError(try adapter.playUrl(chapter: chapter), "应拦截：\(url)")
        }
    }
}
