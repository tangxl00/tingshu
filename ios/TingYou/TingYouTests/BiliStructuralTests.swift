import XCTest
@testable import TingYou

/// build 29 · B站音源结构断言（B1-B12）。
/// 纯逻辑/常量/解析器组件，无需网络即可验证。
final class BiliStructuralTests: XCTestCase {

    // MARK: - B1 · 域名白名单放行 bilibili 系与 CDN 域

    func testHostAllowedAcceptsBilibiliDomains() {
        XCTAssertTrue(BiliSource.hostAllowed("www.bilibili.com"))
        XCTAssertTrue(BiliSource.hostAllowed("bilibili.com"))
        XCTAssertTrue(BiliSource.hostAllowed("api.bilibili.com"))
        XCTAssertTrue(BiliSource.hostAllowed("b23.tv"))
        XCTAssertTrue(BiliSource.hostAllowed("bilivideo.com"))
        XCTAssertTrue(BiliSource.hostAllowed("biliapi.net"))
        XCTAssertTrue(BiliSource.hostAllowed("akamaized.net"))
        XCTAssertTrue(BiliSource.hostAllowed("hdslb.com"))
        XCTAssertTrue(BiliSource.hostAllowed("i0.hdslb.com"))
    }

    // MARK: - B2 · 域名白名单拒绝非 bilibili 域与后缀伪造

    func testHostAllowedRejectsForeignAndLookalikeDomains() {
        XCTAssertFalse(BiliSource.hostAllowed("evil.example.com"))
        XCTAssertFalse(BiliSource.hostAllowed("bilibili.com.evil.com"))
        XCTAssertFalse(BiliSource.hostAllowed("notbilibili.com"))
        XCTAssertFalse(BiliSource.hostAllowed(""))
    }

    // MARK: - B3 · 导入解析支持 BV 号

    func testInputParserAcceptsBVNumber() {
        let result = BiliInputParser.parse("BV1xx411c7mD")
        guard case .video(let bvid) = result else {
            XCTFail("BV 号应解析为 video")
            return
        }
        XCTAssertEqual(bvid, "BV1xx411c7mD")
    }

    func testInputParserAcceptsAvNumber() {
        let result = BiliInputParser.parse("av123456")
        guard case .av(let aid) = result else {
            XCTFail("av 号应解析为 av")
            return
        }
        XCTAssertEqual(aid, 123456)
    }

    func testInputParserAcceptsBilibiliUrl() {
        let result = BiliInputParser.parse("https://www.bilibili.com/video/BV1xx411c7mD")
        guard case .video(let bvid) = result else {
            XCTFail("B站链接应解析出 video")
            return
        }
        XCTAssertEqual(bvid, "BV1xx411c7mD")
    }

    func testInputParserAcceptsShortLink() {
        let result = BiliInputParser.parse("https://b23.tv/abc123")
        guard case .shortLink(let url) = result else {
            XCTFail("b23.tv 短链应解析为 shortLink")
            return
        }
        XCTAssertEqual(url, "https://b23.tv/abc123")
    }

    // MARK: - B4 · 解析器对非 B站链接一律拒绝

    func testInputParserRejectsEvilDomain() {
        XCTAssertNil(BiliInputParser.parse("https://evil.com/video/BV1xx411c7mD"))
    }

    func testInputParserRejectsPlainText() {
        XCTAssertNil(BiliInputParser.parse("hello world"))
    }

    // MARK: - B5 · 章节占位 URI 往返可解析

    func testChapterUriRoundTrip() {
        let uri = BiliSource.buildChapterUri(bvid: "BV1xx411c7mD", cid: 12345)
        XCTAssertTrue(BiliSource.isBiliChapterUri(uri))
        let parsed = BiliSource.parseChapterUri(uri)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.bvid, "BV1xx411c7mD")
        XCTAssertEqual(parsed?.cid, 12345)
    }

    func testChapterUriRejectsMalformed() {
        XCTAssertNil(BiliSource.parseChapterUri("tingyou-bili://audio?bvid=&cid=123"))
        XCTAssertNil(BiliSource.parseChapterUri("tingyou-bili://audio?bvid=BV1&cid=0"))
        XCTAssertNil(BiliSource.parseChapterUri("https://example.com"))
    }

    // MARK: - B6 · buvid3 生成 32 位且同种子可复现

    func testGenBuvid3LengthAndReproducibility() {
        let a = BiliAdapter.genBuvid3(seed: 42)
        let b = BiliAdapter.genBuvid3(seed: 42)
        XCTAssertEqual(a.count, 32, "buvid3 必须为 32 位")
        XCTAssertEqual(a, b, "同种子必须可复现")
        XCTAssertNotEqual(BiliAdapter.genBuvid3(seed: 43), a, "不同种子应不同")
    }

    // MARK: - B7 · 搜索 URL 构造含签名与范围限定

    func testBuildSearchUrlContainsRequiredParams() {
        let url = BiliSearchApi.buildSearchUrl(
            apiBase: "https://api.bilibili.com",
            keyword: "有声小说",
            page: 1,
            order: "totalrank",
            wbiKey: "deadbeefdeadbeefdeadbeefdeadbeef",
            wtsSeconds: 1700000000
        )
        XCTAssertTrue(url.contains("search_type=video"), "必须限定搜索范围为 video")
        XCTAssertTrue(url.contains("w_rid="), "必须含 WBI 签名")
        XCTAssertTrue(url.contains("wts=1700000000"), "必须含时间戳")
        XCTAssertTrue(url.contains("keyword="), "必须含关键词")
        XCTAssertTrue(url.contains("page=1"), "必须含页码")
    }

    // MARK: - B8 · WBI 混合密钥按官方重排列取前 32 位

    func testMixinKeyLengthAndStability() {
        let key = BiliSearchApi.mixinKey(
            imgUrl: "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
            subUrl: "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"
        )
        XCTAssertEqual(key.count, 32, "mixinKey 输出必须为 32 位")
        let key2 = BiliSearchApi.mixinKey(
            imgUrl: "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
            subUrl: "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"
        )
        XCTAssertEqual(key, key2, "同一输入必须稳定")
    }

    // MARK: - B9 · 412 阶梯退避常量符合设计

    func testBackoffMillisMatchesDesign() {
        // 设计文档：1200ms / 2600ms / 5000ms
        // 代码中以纳秒存储
        XCTAssertEqual(BiliAdapter.BACKOFF_MILLIS, [1_200_000_000, 2_600_000_000, 5_000_000_000])
    }

    // MARK: - B10 · 访客态最小请求间隔

    func testMinRequestGapMatchesDesign() {
        // 设计文档：450ms
        XCTAssertEqual(BiliAdapter.MIN_REQUEST_GAP_NS, 450_000_000)
    }

    // MARK: - B11 · 适配器已装配到播放与路由（结构存在性）

    func testPlaybackRepositoryAcceptsBiliAdapter() {
        // 若能成功构造（含 biliAdapter 参数）即证明装配点存在
        let repo = PlaybackRepository(
            apiClient: APIClient(),
            msrcAdapter: MsrcAdapter(apiClient: APIClient()),
            ytysxsAdapter: YtysxsAdapter(apiClient: APIClient()),
            mekuiAdapter: MekuiAdapter(apiClient: APIClient()),
            biliAdapter: BiliAdapter(),
            ting59Adapter: Ting59Adapter()
        )
        XCTAssertNotNil(repo)
    }

    // MARK: - B12 · 路由暴露 B站搜索/分类（结构存在性）

    func testSourceRouterAcceptsBiliSearchApi() {
        let biliAdapter = BiliAdapter()
        let router = SourceRouter(
            apiClient: APIClient(),
            biliAdapter: biliAdapter,
            biliSearchApi: BiliSearchApi(adapter: biliAdapter),
            ting59Adapter: Ting59Adapter()
        )
        XCTAssertNotNil(router)
    }

    func testBiliCategoriesNonEmpty() {
        XCTAssertFalse(BiliCategories.ALL.isEmpty, "BiliCategories 必须非空")
        XCTAssertNotNil(BiliCategories.of("hot"))
    }

    // MARK: - gaia 载荷格式

    func testBuildGaiaPayloadFormat() {
        let payload = BiliAdapter.buildGaiaPayload(mid: 1, buvid3: "abc123", buvid4: "def456")
        XCTAssertTrue(payload.contains("\"mid\":1"))
        XCTAssertTrue(payload.contains("\"buvid3\":\"abc123\""))
        XCTAssertTrue(payload.contains("\"buvid4\":\"def456\""))
    }
}
