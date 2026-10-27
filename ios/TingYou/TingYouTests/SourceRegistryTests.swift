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
        XCTAssertTrue(SourceRegistry.isKnown(src: "ytysxs"))
        XCTAssertTrue(SourceRegistry.isKnown(src: "bili"))
        // build 38 · 反馈 1：ting59（59听书网）下架
        XCTAssertFalse(SourceRegistry.isKnown(src: "ting59"), "59听书网已下架")
    }

    func testDelistedSourcesHaveNoConfigAndFallbackDisplayName() {
        XCTAssertNil(SourceRegistry.configOf(src: "ting15"), "听十五已下架，config 不得残留")
        XCTAssertNil(SourceRegistry.configOf(src: "mekui"), "书音FM 已下架，config 不得残留")
        XCTAssertNil(SourceRegistry.configOf(src: "ting08"))
        XCTAssertNil(SourceRegistry.configOf(src: "nope"))
        XCTAssertTrue(SourceRegistry.msrcSources.isEmpty, "MSRC 注册表应已清空")
        XCTAssertEqual(SourceRegistry.displayName(src: "ting15"), "ting15", "下架源显示名回落原始 id")
        XCTAssertEqual(SourceRegistry.displayName(src: "mekui"), "mekui", "下架源显示名回落原始 id")
        XCTAssertEqual(SourceRegistry.displayName(src: "tingyou"), "听友FM")
        XCTAssertEqual(SourceRegistry.externalKey(src: "tingyou", albumId: 123), "123")
        XCTAssertEqual(SourceRegistry.externalKey(src: "ting15", albumId: 123), "ting15:123")
    }

    func testImageRefererClearedAfterDelisting() {
        XCTAssertTrue(SourceRegistry.allImgHosts.isEmpty, "MSRC 源全下架后无注册图床")
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
        let hosts = SourceRegistry.msrcSources.values
            .flatMap { $0.fetchHosts + $0.imgHosts + $0.audioExact + $0.audioSuffixes }
        XCTAssertFalse(hosts.contains(where: { $0.contains("wx.qq.com") }))
        XCTAssertFalse(hosts.contains(where: { $0.contains("xmcdn") }))
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
