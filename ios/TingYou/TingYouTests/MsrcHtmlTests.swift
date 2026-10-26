import XCTest
@testable import TingYou

/// ting15（及已下架 ting08 模板形态）宽容解析（MsrcHtml）黄金样本测试：
/// 搜索 / 详情 / 两步 token 播放响应，覆盖 BOM、status 双形态、付费/频控码。
final class MsrcHtmlTests: XCTestCase {

    // MARK: - 搜索

    private let ting15SearchHtml = """
    <html><body>
    <div class="clist">
    <a href="/youshengxiaoshuo/1001.html" title="斗罗大陆"><dl><dt><img src="https://img.ting15.com/1001.jpg" alt="斗罗大陆"/><h3 class="t">斗罗大陆</h3><dd><p>作者：唐家三少</p><p>播音：小C</p></dd></dl></a>
    <a href="/youshengxiaoshuo/1002.html"><dl><dt><img src="https://img.ting15.com/1002.jpg"/><h3>完美世界</h3><dd><p>作者：辰东</p><p>播音：小D</p></dd></dl></a>
    <a href="/youshengxiaoshuo/1001.html"><dl><dt><img src="https://img.ting15.com/1001.jpg"/><h3>斗罗大陆（重复项）</h3><dd></dd></dl></a>
    </div>
    <div class="cpage">第 1 页</div>
    </body></html>
    """

    private let ting08SearchHtml = """
    <html><body>
    <div class="category-list">
    <li><div class="img"><a href="/book/2001.html"><img src="https://img.ting08.com/2001.jpg"/><h4 class="title"><a href="/book/2001.html">遮天</a></h4><dd>作者：辰东<br/>播音：小E</dd></div></li>
    </div>
    <aside>侧栏</aside>
    </body></html>
    """

    func testParseSearchTing15Golden() {
        let items = MsrcHtml.parseSearch(cfg: SourceRegistry.ting15, html: ting15SearchHtml)
        XCTAssertEqual(items.count, 2, "同 detailPath 的第三条应去重")
        XCTAssertEqual(items[0].title, "斗罗大陆")
        XCTAssertEqual(items[0].detailPath, "/youshengxiaoshuo/1001.html")
        XCTAssertEqual(items[0].bookId, "1001")
        XCTAssertEqual(items[0].author, "唐家三少")
        XCTAssertEqual(items[0].teller, "小C")
        XCTAssertEqual(items[0].cover, "https://img.ting15.com/1001.jpg")
        XCTAssertEqual(items[1].title, "完美世界")
        XCTAssertEqual(items[1].author, "辰东")
    }

    /// build 36 · 反馈 4：听吧（ting08）源已下架（SourceRegistry.ting08 删除），
    /// 但 MsrcHtml 基础设施保留（ting15 共用）——该模板形态
    /// （category-list 切片 + &lt;aside 边界）的解析能力以本地构造的同形态 config 继续守护。
    func testParseSearchTing08TemplateGolden() {
        let ting08Cfg = SourceRegistry.MsrcSourceConfig(
            id: "ting08", name: "听吧",
            siteBase: "https://www.ting08.com", referer: "https://www.ting08.com/",
            searchPOST: true, extraLHeader: true,
            searchStart: "class=\"category-list\"", searchEnd: "<aside",
            fetchHosts: ["www.ting08.com"],
            imgHosts: ["img-book-oss.guoguo.org.cn"],
            audioExact: ["oss-links.guoguo.org.cn"],
            audioSuffixes: [".guoguo.org.cn"])
        let items = MsrcHtml.parseSearch(cfg: ting08Cfg, html: ting08SearchHtml)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "遮天")
        XCTAssertEqual(items[0].detailPath, "/book/2001.html")
        XCTAssertEqual(items[0].bookId, "2001")
        XCTAssertEqual(items[0].author, "辰东")
        XCTAssertEqual(items[0].teller, "小E")
    }

    func testParseSearchEmptyHtmlDegradesToEmpty() {
        XCTAssertTrue(MsrcHtml.parseSearch(cfg: SourceRegistry.ting15, html: "").isEmpty)
        XCTAssertTrue(MsrcHtml.parseSearch(cfg: SourceRegistry.ting15, html: "<html>404</html>").isEmpty)
    }

    // MARK: - 详情

    private let detailHtml = """
    <html><body>
    <div class="book">
      <h1 class="pt">斗罗大陆有声小说</h1>
      <div class="bimg"><img src="https://img.ting15.com/big.jpg"/></div>
      <p>作者：唐家三少</p>
      <p>播音：小C</p>
      <p>状态：完结</p>
    </div>
    <div class="playlist">
      <div class="plist">
        <a href="/youshengxiaoshuo/1001/0-3.html">第003集</a>
        <a href="/youshengxiaoshuo/1001/0-1.html">第001集</a>
        <a href="/youshengxiaoshuo/1001/0-2.html">第002集</a>
        <a href="/youshengxiaoshuo/1001/0-2.html">第002集（重复）</a>
      </div>
    </div>
    <div class="intro"><p>一个武魂的世界。</p></div>
    </body></html>
    """

    func testParseDetailGolden() {
        let d = MsrcHtml.parseDetail(detailHtml)
        XCTAssertEqual(d.title, "斗罗大陆", "标题应剥掉「有声小说」后缀")
        XCTAssertEqual(d.author, "唐家三少")
        XCTAssertEqual(d.teller, "小C")
        XCTAssertEqual(d.statusText, "完结")
        XCTAssertEqual(d.cover, "https://img.ting15.com/big.jpg")
        XCTAssertEqual(d.intro, "一个武魂的世界。")
        XCTAssertEqual(d.chapterCount, 3, "重复章节应去重")
        XCTAssertEqual(d.chapters[0].page, 1)
        XCTAssertEqual(d.chapters[0].title, "第001集")
        XCTAssertEqual(d.chapters[2].page, 3, "章节按 page 升序")
    }

    // MARK: - 两步 token：播放页 meta

    func testParsePlayPageExtractsTokenAndPayFlag() {
        let html = """
        <html><head>
        <meta name="_c" content="tok_abc123"/>
        <meta name="_p" content="1"/>
        </head><body></body></html>
        """
        let meta = MsrcHtml.parsePlayPage(html)
        XCTAssertNotNil(meta)
        XCTAssertEqual(meta?.token, "tok_abc123")
        XCTAssertEqual(meta?.isPay, "1")
    }

    func testParsePlayPageDefaultsPayFlagToZero() {
        let meta = MsrcHtml.parsePlayPage(#"<meta name="_c" content="tok"/>"#)
        XCTAssertEqual(meta?.isPay, "0")
    }

    func testParsePlayPageReturnsNilWithoutToken() {
        XCTAssertNil(MsrcHtml.parsePlayPage(#"<meta name="_p" content="0"/>"#))
        XCTAssertNil(MsrcHtml.parsePlayPage("<html></html>"))
    }

    // MARK: - 两步 token：播放接口响应

    func testParsePlayResponseSuccessPrefersOurl() {
        let r = MsrcHtml.parsePlayResponse(#"{"status":1,"ourl":"https://file.hgeuz.cn/a/1.mp3","url":"https://fallback/1.mp3"}"#)
        XCTAssertEqual(r.status, 1)
        XCTAssertEqual(r.url, "https://file.hgeuz.cn/a/1.mp3")
    }

    func testParsePlayResponseFallsBackToUrlField() {
        let r = MsrcHtml.parsePlayResponse(#"{"status":1,"url":"https://file.hgeuz.cn/a/2.mp3"}"#)
        XCTAssertEqual(r.status, 1)
        XCTAssertEqual(r.url, "https://file.hgeuz.cn/a/2.mp3")
    }

    func testParsePlayResponseStringStatusForm() {
        let r = MsrcHtml.parsePlayResponse(#"{"status":"1","ourl":"https://file.hgeuz.cn/a/3.mp3"}"#)
        XCTAssertEqual(r.status, 1)
        XCTAssertEqual(r.url, "https://file.hgeuz.cn/a/3.mp3")
    }

    func testParsePlayResponsePaidMinusOne() {
        let r = MsrcHtml.parsePlayResponse(#"{"status":-1,"msg":"付费章节"}"#)
        XCTAssertEqual(r.status, -1)
        XCTAssertNil(r.url)
    }

    func testParsePlayResponseRateLimitMinusTwo() {
        let r = MsrcHtml.parsePlayResponse(#"{"status":"-2","msg":"请求过快"}"#)
        XCTAssertEqual(r.status, -2)
        XCTAssertNil(r.url)
    }

    func testParsePlayResponseStripsBom() {
        let raw = "\u{FEFF}" + #"{"status":1,"ourl":"https://file.hgeuz.cn/a/4.mp3"}"#
        let r = MsrcHtml.parsePlayResponse(raw)
        XCTAssertEqual(r.status, 1, "带 UTF-8 BOM 的响应应先剥 BOM 再解析")
        XCTAssertEqual(r.url, "https://file.hgeuz.cn/a/4.mp3")
    }

    func testParsePlayResponseEmptyUrlIsError() {
        let r = MsrcHtml.parsePlayResponse(#"{"status":1,"ourl":""}"#)
        XCTAssertEqual(r.status, 0)
        XCTAssertNil(r.url)
    }

    // MARK: - 工具函数

    func testExtractJsonStringFieldUnescapes() {
        let json = #"{"url":"https:\/\/x\/a.mp3","t":"say \"hi\""}"#
        XCTAssertEqual(MsrcHtml.extractJsonStringField(json, "url"), "https://x/a.mp3")
        XCTAssertEqual(MsrcHtml.extractJsonStringField(json, "t"), #"say "hi""#)
        XCTAssertNil(MsrcHtml.extractJsonStringField(json, "missing"))
    }

    func testEncodeUriComponentSpaceAsPercent20() {
        // 表单语义会把空格编码为 +，此处必须还原为 %20（安卓 encodeUriComponent 语义）
        XCTAssertEqual(MsrcHtml.encodeUriComponent("斗罗 大陆"), "%E6%96%97%E7%BD%97%20%E5%A4%A7%E9%99%86")
        XCTAssertEqual(MsrcHtml.encodeUriComponent("a+b"), "a+b")
        XCTAssertFalse(MsrcHtml.encodeUriComponent("a b").contains("+"))
    }

    func testEncodeUriComponentAsciiOnlyWhitelist() {
        // 中文必须全部转义（安卓 encodeUriComponent 语义：白名单仅 ASCII）
        XCTAssertEqual(MsrcHtml.encodeUriComponent("斗罗大陆"), "%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86")
        XCTAssertEqual(MsrcHtml.encodeUriComponent("完美 世界"), "%E5%AE%8C%E7%BE%8E%20%E4%B8%96%E7%95%8C")
        // 保留字符必须转义
        XCTAssertEqual(MsrcHtml.encodeUriComponent("a&b=c/d?e#f"), "a%26b%3Dc%2Fd%3Fe%23f")
        XCTAssertEqual(MsrcHtml.encodeUriComponent("100%"), "100%25")
        // 安全符号原样保留
        XCTAssertEqual(MsrcHtml.encodeUriComponent("id-_.!~*'()"), "id-_.!~*'()")
        XCTAssertEqual(MsrcHtml.encodeUriComponent(""), "")
        // 幂等性：已编码文本不应二次编码（% 与十六进制安全）
        XCTAssertEqual(MsrcHtml.encodeUriComponent("%E6%96%97"), "%25E6%2596%2597")
    }
}
