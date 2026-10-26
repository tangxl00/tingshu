import XCTest
@testable import TingYou

final class SourceRegistryTests: XCTestCase {

    func testAllConfiguredHostsAreWellFormedAndCovered() {
        let allSources = [SourceRegistry.ting15]
        for cfg in allSources {
            XCTAssertTrue(cfg.siteBase.hasPrefix("https://"))
            let site = cfg.siteBase.replacingOccurrences(of: "https://", with: "")
            XCTAssertEqual(site, cfg.fetchHosts.first)
            XCTAssertEqual(cfg.fetchHosts.count, 1)
            for host in cfg.fetchHosts {
                XCTAssertTrue(SourceRegistry.fetchHostAllowed(cfg: cfg, host: host))
            }
            for host in cfg.imgHosts {
                XCTAssertTrue(SourceRegistry.fetchHostAllowed(cfg: cfg, host: host))
            }
            for host in cfg.audioExact {
                XCTAssertTrue(SourceRegistry.audioHostAllowed(cfg: cfg, host: host))
            }
        }

        let mk = SourceRegistry.mekui
        XCTAssertTrue(mk.fetchHosts.allSatisfy { SourceRegistry.fetchHostAllowed(cfg: mk, host: $0) })
        XCTAssertTrue(mk.imgHosts.allSatisfy { SourceRegistry.fetchHostAllowed(cfg: mk, host: $0) })
        XCTAssertTrue(mk.audioExact.allSatisfy { SourceRegistry.audioHostAllowed(cfg: mk, host: $0) })
    }

    func testDefensiveEntriesFromPcAreAbsent() {
        let hosts = SourceRegistry.msrcSources.values
            .flatMap { $0.fetchHosts + $0.imgHosts + $0.audioExact + $0.audioSuffixes }
        XCTAssertFalse(hosts.contains(where: { $0.contains("wx.qq.com") }))
        XCTAssertFalse(hosts.contains(where: { $0.contains("xmcdn") }))
    }

    func testFetchWhitelistRejectsForeignHosts() {
        let cfg = SourceRegistry.ting15
        XCTAssertFalse(SourceRegistry.fetchHostAllowed(cfg: cfg, host: "evil.example.com"))
        XCTAssertFalse(SourceRegistry.fetchHostAllowed(cfg: cfg, host: "m.ting15.com.evil.com"))
        XCTAssertFalse(SourceRegistry.fetchHostAllowed(cfg: cfg, host: ""))
        XCTAssertTrue(SourceRegistry.fetchHostAllowed(cfg: SourceRegistry.ting15, host: "img-book-oss.guoguo.org.cn"))
    }

    func testAudioWhitelistAcceptsExactAndSuffixButRejectsOthers() {
        let cfg = SourceRegistry.ting15
        XCTAssertTrue(SourceRegistry.audioHostAllowed(cfg: cfg, host: "oss-links.guoguo.org.cn"))
        XCTAssertTrue(SourceRegistry.audioHostAllowed(cfg: cfg, host: "cloud.guoguo.org.cn"))
        XCTAssertTrue(SourceRegistry.audioHostAllowed(cfg: cfg, host: "cdn-3.guoguo.org.cn"))
        XCTAssertFalse(SourceRegistry.audioHostAllowed(cfg: cfg, host: "guoguo.org.cn.evil.com"))
        XCTAssertFalse(SourceRegistry.audioHostAllowed(cfg: cfg, host: "evil-guoguo.org.cn"))
        XCTAssertFalse(SourceRegistry.audioHostAllowed(cfg: cfg, host: "oss-links.guoguo.org.cn.evil.com"))
        XCTAssertFalse(SourceRegistry.audioHostAllowed(cfg: cfg, host: "tingyou.fm"))
    }

    func testRegistryLookupAndDisplayNames() {
        XCTAssertTrue(SourceRegistry.isKnown(src: "tingyou"))
        XCTAssertTrue(SourceRegistry.isKnown(src: "ting15"))
        // build 36 · 反馈 4：听吧已下架——不再注册
        XCTAssertFalse(SourceRegistry.isKnown(src: "ting08"))
        XCTAssertFalse(SourceRegistry.isKnown(src: "ting20"))
        XCTAssertEqual(SourceRegistry.displayName(src: "tingyou"), "听友FM")
        XCTAssertEqual(SourceRegistry.displayName(src: "ting15"), "听十五")
        XCTAssertNotNil(SourceRegistry.configOf(src: "ting15"))
        XCTAssertNil(SourceRegistry.configOf(src: "nope"))
        XCTAssertEqual(SourceRegistry.externalKey(src: "tingyou", albumId: 123), "123")
        XCTAssertEqual(SourceRegistry.externalKey(src: "ting15", albumId: 123), "ting15:123")
    }

    func testImageRefererCoversAllImgHosts() {
        for host in SourceRegistry.allImgHosts {
            let referer = SourceRegistry.imageRefererFor(host: host)
            XCTAssertNotNil(referer, "图片域 \(host) 必须有 Referer")
            XCTAssertTrue(referer!.hasPrefix("https://"))
        }
        XCTAssertNil(SourceRegistry.imageRefererFor(host: "file.hgeuz.cn"))
        XCTAssertNil(SourceRegistry.imageRefererFor(host: "tingyou.fm"))
    }
}
