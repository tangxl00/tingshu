import XCTest
@testable import TingYou

/// build 36 · 反馈 2（B站播放 cannot open）：proxyMedia 出站请求头注入单测。
/// 沙箱分离实验：裸请求 403、仅 Cookie 403、仅加 `Referer: https://www.bilibili.com`
/// 即 206（content-range bytes 0-0/5408198）——bilivideo.com 音频 CDN 强制校验 Referer。
/// 锁定 applyBiliCdnHeaders 的注入逻辑：代理 CDN 域注入 Referer + 与 BiliAdapter
/// 一致的 UA；非代理域不注入（头保持原样）；Range 头不被覆盖。
final class BiliCdnHeadersTests: XCTestCase {

    func testProxiedBiliCdnHostsGetRefererAndUA() {
        // build 36 返修（CI #1）：B站图床真实域是 hdslb.com（ProxiedCdnHosts 白名单后缀为 .com），
        // 此前误写 .cn 不在白名单 → 头不注入 → 断言必败（两轮 0.59s/0.66s 稳定复现）。
        // 修测试用例域名，不改产品白名单（.cn 域真实性未证实，不得入白名单）。
        for host in ["upos-sz-mirror8.bilivideo.com", "bilivideo.com",
                     "cdn.example.akamaized.net", "i0.hdslb.com"] {
            var req = URLRequest(url: URL(string: "https://\(host)/a.mp3")!)
            PlaybackManager.applyBiliCdnHeaders(to: &req, url: req.url!)
            XCTAssertEqual(req.value(forHTTPHeaderField: "Referer"), BiliAdapter.REFERER,
                           "\(host) 出站请求必须注入 B站 Referer")
            XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), BiliAdapter.USER_AGENT,
                           "\(host) 出站请求必须注入与 BiliAdapter 一致的 UA")
        }
    }

    func testNonProxiedHostsGetNoInjectedHeaders() {
        for host in ["www.bilibili.com", "api.bilibili.com", "tingyou.fm", "www.ting15.com"] {
            var req = URLRequest(url: URL(string: "https://\(host)/a")!)
            PlaybackManager.applyBiliCdnHeaders(to: &req, url: req.url!)
            XCTAssertNil(req.value(forHTTPHeaderField: "Referer"),
                         "\(host) 非代理 CDN 域不得注入 Referer")
            XCTAssertNil(req.value(forHTTPHeaderField: "User-Agent"),
                         "\(host) 非代理 CDN 域不得注入 UA")
        }
    }

    func testRangeHeaderPreservedAlongsideInjectedHeaders() {
        var req = URLRequest(url: URL(string: "https://upos-sz-mirror8.bilivideo.com/a.mp3")!)
        req.setValue("bytes=0-", forHTTPHeaderField: "Range")
        PlaybackManager.applyBiliCdnHeaders(to: &req, url: req.url!)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Range"), "bytes=0-", "Range 头不被注入逻辑覆盖")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Referer"), BiliAdapter.REFERER)
    }

    func testInvalidURLDoesNotCrash() {
        // 无 host 的 URL：guard 兜底，不注入、不崩溃
        guard let url = URL(string: "https:///nohost") else {
            return // 平台差异下构造失败也无从断言，直接跳过
        }
        var req = URLRequest(url: url)
        PlaybackManager.applyBiliCdnHeaders(to: &req, url: url)
        XCTAssertNil(req.value(forHTTPHeaderField: "Referer"))
    }
}
