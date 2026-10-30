import XCTest
@testable import TingYou

/// build 37 · 反馈 1：听十五（ting15）/ 书音FM（mekui）下架（同 build 36 删 ting08
/// 模式）——本套件由「已注册源核对」改写为「下架源 delisted 断言 + 白名单纯函数守护」。
/// MsrcSourceConfig 白名单纯函数（fetchHostAllowed / audioHostAllowed）与源存续无关，
/// 以本地构造的同形态 config 继续守护（解析器与白名单逻辑保留，供同类源复用）。
final class SourceRegistryTests: XCTestCase {

    /// 下架前 ting15 的同形态本地 config（原 SourceRegistry.ting15 黄金值）。
    private func ting15Cfg() -> SourceRegistry.MsrcSourceConfig {
        SourceRegistry.MsrcSourceConfig(
            id: "ting15", name: "听十五",
            siteBase: "https://m.ting15.com", referer: "https://m.ting15.com/",
            searchPOST: false, extraLHeader: false,
            searchStart: "class=\"clist\"", searchEnd: "class=\"cpage\"",
            fetchHosts: ["m.ting15.com"],
            imgHosts: ["img-book-oss.guoguo.org.cn", "img-south-oss.guoguo.org.cn"],
            audioExact: ["oss-links.guoguo.org.cn", "cloud.guoguo.org.cn"],
            audioSuffixes: [".guoguo.org.cn"]
        )
    }

    // MARK: - build 37 · 下架源 delisted 断言

    func testDelistedSourcesNotRegistered() {
        // build 36：听吧；build 37：听十五/书音FM——均不得再注册为已知源
        XCTAssertFalse(SourceRegistry.isKnown(src: "ting08"))
        XCTAssertFalse(SourceRegistry.isKnown(src: "ting15"), "听十五已下架")
        XCTAssertFalse(SourceRegistry.isKnown(src: "mekui"), "书音FM 已下架")
        XCTAssertTrue(SourceRegistry.isKnown(src: "tingyou"))
        XCTAssertFalse(SourceRegistry.isKnown(src: "ytysxs"), "悦听已下架（build 45）")
        XCTAssertTrue(SourceRegistry.isKnown(src: "bili"))
        // build 38 · 反馈 1：ting59（59听书网）下架
        XCTAssertFalse(SourceRegistry.isKnown(src: "ting59"), "59听书网已下架")
    }

    func testDelistedSourcesHaveNoConfigAndFallbackDisplayName() {
        XCTAssertNil(SourceRegistry.configOf(src: "ting15"), "听十五已下架，config 不得残留")
        XCTAssertNil(SourceRegistry.configOf(src: "mekui"), "书音FM 已下架，config 不得残留")
        XCTAssertNil(SourceRegistry.configOf(src: "ting08"))
        XCTAssertNil(SourceRegistry.configOf(src: "nope"))
        // build 50：易听书注册进 MSRC（对齐 PC 三源基准），注册表不再为空
        XCTAssertNotNil(SourceRegistry.msrcSources[SourceRegistry.YITINGSHU], "易听书应注册进 MSRC")
        XCTAssertEqual(SourceRegistry.msrcSources.count, 1, "MSRC 仅易听书一个源")
        XCTAssertEqual(SourceRegistry.displayName(src: "ting15"), "ting15", "下架源显示名回落原始 id")
        XCTAssertEqual(SourceRegistry.displayName(src: "mekui"), "mekui", "下架源显示名回落原始 id")
        XCTAssertEqual(SourceRegistry.displayName(src: "tingyou"), "听友FM")
        XCTAssertEqual(SourceRegistry.externalKey(src: "tingyou", albumId: 123), "123")
        XCTAssertEqual(SourceRegistry.externalKey(src: "ting15", albumId: 123), "ting15:123")
    }

    func testImageRefererClearedAfterDelisting() {
        // build 50：易听书图床 imagev2.xmcdn.com 注册（其余下架源图床 referer 仍不得残留）
        XCTAssertTrue(SourceRegistry.allImgHosts.contains("imagev2.xmcdn.com"), "易听书图床应注册")
        XCTAssertNil(SourceRegistry.imageRefererFor(host: "img-book-oss.guoguo.org.cn"),
                     "ting15/ting08 下架后 guoguo 图床不再配 referer")
        XCTAssertNil(SourceRegistry.imageRefererFor(host: "shuyinfm.oss-cn-hangzhou.aliyuncs.com"),
                     "书音FM 下架后其图床不再配 referer")
        XCTAssertNil(SourceRegistry.imageRefererFor(host: "file.hgeuz.cn"))
        XCTAssertNil(SourceRegistry.imageRefererFor(host: "tingyou.fm"))
        XCTAssertNil(SourceRegistry.imageRefererFor(host: "img-book-oss.guoguo.org.cn", source: "ting15"),
                     "已下架源上下文同样无 referer")
    }

    func testDefensiveEntriesFromPcAreAbsent() {
        // build 50 改写：易听书（对齐 PC v1.1.8）合法使用 xmcdn 图床/音频域，
        // 原 blanket 断言「不得含 xmcdn」随之退役；wx.qq.com 防御性条目守卫保留。
        let yts = SourceRegistry.msrcSources[SourceRegistry.YITINGSHU]
        let hosts = SourceRegistry.msrcSources.values
            .flatMap { $0.fetchHosts + $0.imgHosts + $0.audioExact + $0.audioSuffixes }
        XCTAssertFalse(hosts.contains(where: { $0.contains("wx.qq.com") }))
        XCTAssertEqual(yts?.imgHosts, ["imagev2.xmcdn.com"], "易听书图床仅 imagev2.xmcdn.com")
        XCTAssertEqual(yts?.audioExact, ["aod.cos.tx.xmcdn.com"], "易听书音频域仅 aod.cos.tx.xmcdn.com（PC 实测 15/15 落此域）")
        XCTAssertEqual(yts?.fetchHosts, ["www.yitingshu.com"], "易听书抓取域仅 www.yitingshu.com")
    }

    // MARK: - 白名单纯函数守护（本地同形态 config，逻辑与源存续无关）

    func testFetchWhitelistRejectsForeignHosts() {
        let cfg = ting15Cfg()
        XCTAssertTrue(SourceRegistry.fetchHostAllowed(cfg: cfg, host: "m.ting15.com"))
        XCTAssertTrue(SourceRegistry.fetchHostAllowed(cfg: cfg, host: "img-book-oss.guoguo.org.cn"))
        XCTAssertFalse(SourceRegistry.fetchHostAllowed(cfg: cfg, host: "evil.example.com"))
        XCTAssertFalse(SourceRegistry.fetchHostAllowed(cfg: cfg, host: "m.ting15.com.evil.com"))
        XCTAssertFalse(SourceRegistry.fetchHostAllowed(cfg: cfg, host: ""))
    }

    func testAudioWhitelistAcceptsExactAndSuffixButRejectsOthers() {
        let cfg = ting15Cfg()
        XCTAssertTrue(SourceRegistry.audioHostAllowed(cfg: cfg, host: "oss-links.guoguo.org.cn"))
        XCTAssertTrue(SourceRegistry.audioHostAllowed(cfg: cfg, host: "cloud.guoguo.org.cn"))
        XCTAssertTrue(SourceRegistry.audioHostAllowed(cfg: cfg, host: "cdn-3.guoguo.org.cn"))
        XCTAssertFalse(SourceRegistry.audioHostAllowed(cfg: cfg, host: "guoguo.org.cn.evil.com"))
        XCTAssertFalse(SourceRegistry.audioHostAllowed(cfg: cfg, host: "evil-guoguo.org.cn"))
        XCTAssertFalse(SourceRegistry.audioHostAllowed(cfg: cfg, host: "oss-links.guoguo.org.cn.evil.com"))
        XCTAssertFalse(SourceRegistry.audioHostAllowed(cfg: cfg, host: "tingyou.fm"))
    }
}
