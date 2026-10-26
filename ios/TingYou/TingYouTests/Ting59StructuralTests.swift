import XCTest
@testable import TingYou

/// build 29 · 59听书网音源结构断言（T1-T11）。
/// 纯逻辑/常量/解析器组件，fixture HTML 离线验证，无需网络。
final class Ting59StructuralTests: XCTestCase {

    // MARK: - T1 · 域名白名单只放行 ting59 系与音频 CDN 域

    func testHostAllowedAcceptsTing59Domains() {
        XCTAssertTrue(Ting59Source.hostAllowed("www.ting59.com"))
        XCTAssertTrue(Ting59Source.hostAllowed("ting59.com"))
        XCTAssertTrue(Ting59Source.hostAllowed("m.ting59.com"))
        XCTAssertTrue(Ting59Source.hostAllowed("xmcdn.com"))
        XCTAssertTrue(Ting59Source.hostAllowed("audio.xmcdn.com"))
        XCTAssertTrue(Ting59Source.hostAllowed("aod.cos.tx.xmcdn.com"))
    }

    // MARK: - T2 · 域名白名单拒绝陌生域与后缀伪造

    func testHostAllowedRejectsForeignAndLookalikeDomains() {
        XCTAssertFalse(Ting59Source.hostAllowed("evil.example.com"))
        XCTAssertFalse(Ting59Source.hostAllowed("ting59.com.evil.com"))
        XCTAssertFalse(Ting59Source.hostAllowed("notting59.com"))
        XCTAssertFalse(Ting59Source.hostAllowed("xmcdn.com.evil.com"))
        XCTAssertFalse(Ting59Source.hostAllowed(""))
    }

    // MARK: - T3 · 导入解析支持 www 与 m 站书籍链接

    func testInputParserAcceptsWwwDetailUrl() {
        XCTAssertEqual(
            Ting59InputParser.parse("https://www.ting59.com/mp3/19745.html"),
            "19745"
        )
    }

    func testInputParserAcceptsMobileDetailUrl() {
        XCTAssertEqual(
            Ting59InputParser.parse("https://m.ting59.com/mp3/19745.html"),
            "19745"
        )
    }

    // MARK: - T4 · 导入解析对非 59听书网输入一律拒绝

    func testInputParserRejectsEvilDomain() {
        XCTAssertNil(Ting59InputParser.parse("https://evil.com/mp3/19745.html"))
    }

    func testInputParserRejectsPlainText() {
        XCTAssertNil(Ting59InputParser.parse("19745"))
        XCTAssertNil(Ting59InputParser.parse("hello world"))
    }

    func testInputParserRejectsMissingPath() {
        XCTAssertNil(Ting59InputParser.parse("https://www.ting59.com/"))
    }

    // MARK: - T5 · 章节占位 URI 往返可解析且非法输入拒绝

    func testChapterUriRoundTrip() {
        let uri = Ting59Source.buildChapterUri(bookId: "19745", playIndex: 3)
        XCTAssertTrue(Ting59Source.isTing59ChapterUri(uri))
        let parsed = Ting59Source.parseChapterUri(uri)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.bookId, "19745")
        XCTAssertEqual(parsed?.playIndex, 3)
    }

    func testChapterUriRejectsMalformed() {
        XCTAssertNil(Ting59Source.parseChapterUri("tingyou-ting59://audio?bookId=&playIndex=0"))
        XCTAssertNil(Ting59Source.parseChapterUri("tingyou-ting59://audio?bookId=abc&playIndex=0"))
        XCTAssertNil(Ting59Source.parseChapterUri("tingyou-ting59://audio?bookId=123&playIndex=-1"))
        XCTAssertNil(Ting59Source.parseChapterUri("https://example.com"))
    }

    // MARK: - T6 · 播放页提取 var now 并升级 https

    func testPlayParserExtractsAudioUrlAndUpgradesToHttps() {
        let html = """
        <html><body><script type="text/javascript">
        var now="http://audio.xmcdn.com/group123/M123/abc.m4a";
        </script></body></html>
        """
        let url = try? Ting59PlayParser.extractAudioUrl(html: html)
        XCTAssertEqual(url, "https://audio.xmcdn.com/group123/M123/abc.m4a")
    }

    func testPlayParserPreservesHttps() {
        let html = """
        <script>var now="https://audio.xmcdn.com/group123/M123/abc.m4a";</script>
        """
        let url = try? Ting59PlayParser.extractAudioUrl(html: html)
        XCTAssertEqual(url, "https://audio.xmcdn.com/group123/M123/abc.m4a")
    }

    // MARK: - T7 · 播放页缺 var now 时如实报错

    func testPlayParserThrowsWhenVarNowMissing() {
        let html = "<html><body>no audio here</body></html>"
        XCTAssertThrowsError(try Ting59PlayParser.extractAudioUrl(html: html)) { error in
            let urlErr = error as? URLError
            XCTAssertEqual(urlErr?.code, .badServerResponse)
        }
    }

    // MARK: - T8 · 播放页直链白名单外域被拒绝

    func testPlayParserThrowsOnNonWhitelistedDomain() {
        let html = """
        <script>var now="https://evil.com/audio.mp3";</script>
        """
        XCTAssertThrowsError(try Ting59PlayParser.extractAudioUrl(html: html)) { error in
            let urlErr = error as? URLError
            XCTAssertEqual(urlErr?.code, .badServerResponse)
        }
    }

    // MARK: - T9 · 请求限速常量为每秒两次

    func testMinRequestGapMatchesDesign() {
        // 设计文档：500ms
        XCTAssertEqual(Ting59Adapter.MIN_REQUEST_GAP_MS, 500_000_000)
    }

    // MARK: - T10 · NSC 白名单新增 ting59 与 xmcdn

    func testPinningAllowlistContainsTing59AndXmcdn() {
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("ting59.com"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("www.ting59.com"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("xmcdn.com"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("audio.xmcdn.com"))
    }

    // MARK: - T11 · 适配器已装配到播放与路由（结构存在性）

    func testPlaybackRepositoryAcceptsTing59Adapter() {
        let repo = PlaybackRepository(
            apiClient: APIClient(),
            ytysxsAdapter: YtysxsAdapter(apiClient: APIClient()),
            biliAdapter: BiliAdapter(),
            ting59Adapter: Ting59Adapter()
        )
        XCTAssertNotNil(repo)
    }

    func testSourceRouterAcceptsTing59Adapter() {
        let router = SourceRouter(
            apiClient: APIClient(),
            ting59Adapter: Ting59Adapter()
        )
        XCTAssertNotNil(router)
    }

    // MARK: - 列表解析 fixture 验证（离线 HTML）

    /// build 37 · 反馈 4：真实搜索页 clist 形态为 <div class="clist sear_height">
    /// （fixture 取自 www.ting59.com 搜索页真实结构，带 UTF-8 BOM）——旧精确匹配
    /// 永远落空导致「搜索无结果」；前缀匹配后两种形态都必须解析出条目。
    /// build 37 · 反馈 4：真实搜索页 clist 形态为 <div class="clist sear_height">
    /// （结构取自 www.ting59.com 搜索页真实样本，带 UTF-8 BOM）——旧精确匹配
    /// 永远落空导致「搜索无结果」；前缀匹配后两种形态都必须解析出条目。
    func testListParserHitsSearHeightClistFormWithBom() {
        let html = "\u{FEFF}<div class=\"clist sear_height\"><ul>"
        + "<li><a href=\"/mp3/19745.html\" title=\"测试书\"><img src=\"https://img.ting59.com/19745.jpg\"/></a>"
        + "<dl><dd><a href=\"/mp3/19745.html\" title=\"测试书\"><b>测试书</b></a>"
        + "<p>作者：某作者</p><p>播音：小D</p></dd></dl></li>"
        + "</ul><div class=\"page\">共1条 <a href=\"/search.php?wd=%E4%B9%A6&amp;page=2\">下一页</a></div></div>"
        let result = Ting59ListParsers.parseSearch(doc: html)
        XCTAssertEqual(result.list.count, 1, "sear_height 形态必须解析出条目")
        XCTAssertEqual(result.list.first?.id, "19745")
        XCTAssertEqual(result.list.first?.title, "测试书")
        XCTAssertEqual(result.list.first?.author, "某作者")
        XCTAssertEqual(result.list.first?.narrator, "小D")
        XCTAssertTrue(result.hasMore, "分页区含「下一页」锚点")
        XCTAssertEqual(result.total, 1, "「共1条」总数解析")
    }

    /// build 37 · 反馈 4：分类页 <div class="clist"> 纯形态回归守护（前缀匹配不得破坏旧形态）。
    func testListParserStillHitsPlainClistForm() {
        let html = "<div class=\"clist\"><ul><li><a href=\"/mp3/123.html\" title=\"分类书\"><b>分类书</b></a></li></ul>"
        + "<div class=\"page\">共1条</div></div>"
        let result = Ting59ListParsers.parseSearch(doc: html)
        XCTAssertEqual(result.list.count, 1, "纯 clist 形态继续命中")
        XCTAssertEqual(result.list.first?.id, "123")
    }

    /// build 37 · 反馈 4：同前缀类名（clist2）不得误命中——边界校验回归。
    func testListParserRejectsClistPrefixLookalike() {
        let html = "<div class=\"clist2\"><ul><li><a href=\"/mp3/9.html\" title=\"假条目\"><b>假条目</b></a></li></ul></div>"
        let result = Ting59ListParsers.parseSearch(doc: html)
        XCTAssertTrue(result.list.isEmpty, "clist2 等同前缀类名不得被误认为 clist 容器")
    }

    func testListParserHandlesEmptySearchResult() {
        let html = "<div class=\"clist\"><ul></ul><div class=\"page\">共0条</div></div>"
        let result = Ting59ListParsers.parseSearch(doc: html)
        XCTAssertTrue(result.list.isEmpty)
        XCTAssertFalse(result.hasMore)
    }

    func testDetailParserHandlesMissingIntro() {
        let html = """
        <div class="playbox"><ul><h2><a title="测试书名">测试书名</a></h2></ul></div>
        <div class="numlist border"><ul><li><a href="/play/123-0-0.html">第一集</a></li></ul></div>
        """
        let detail = try? Ting59DetailParser.parse(bookId: "123", html: html)
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.book.title, "测试书名")
        XCTAssertEqual(detail?.chapters.count, 1)
        XCTAssertEqual(detail?.chapters.first?.index, 0)
        XCTAssertEqual(detail?.chapters.first?.title, "第一集")
    }

    // MARK: - Ting59Categories 非空

    func testTing59CategoriesNonEmpty() {
        XCTAssertFalse(Ting59Categories.ALL.isEmpty, "Ting59Categories 必须非空")
        XCTAssertTrue(Ting59Categories.ALL.contains { $0.id == "xuanhuan" })
    }
}
