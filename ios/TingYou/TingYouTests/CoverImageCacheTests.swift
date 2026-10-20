import XCTest
@testable import TingYou

/// build 19 P2-1 / P2-3 回归测试：
/// - P2-1：封面会话必须挂 PinningURLSessionDelegate（证书锚点 + 域名白名单 fail-closed），
///   不允许回退成裸 `URLSessionConfiguration.default`（仅系统信任、绕过校验链路）；
/// - P2-3：防盗链图源（guoguo.org.cn 等）的封面请求必须带 Referer。
///   白名单逻辑本身的 fail-closed 断言复用 RetryAndPinningTests 的 allowlist 骨架。
final class CoverImageCacheTests: XCTestCase {

    // MARK: - P2-1 会话挂载校验

    func testCoverSessionUsesPinningDelegate() {
        // 修复前：URLSession(configuration:) 无 delegate → nil，封面流量绕过证书校验链路
        let delegate = CoverImageCache.shared.session.delegate
        XCTAssertTrue(delegate is PinningURLSessionDelegate,
                      "封面会话必须挂 PinningURLSessionDelegate，实际为 \(String(describing: delegate))")
    }

    func testCoverImageHostsAllWithinAllowlist() {
        // 封面实际会用到的图源域名必须全部在白名单内，否则 P2-1 修复会反过来打挂封面加载
        let coverHosts = SourceRegistry.allImgHosts.union([
            "www.tingyou.fm",          // 听音主站封面
            "img1.tingyou8.vip",       // 听音备用图源（后缀域）
        ])
        for host in coverHosts {
            XCTAssertTrue(PinnedDomainAllowlist.isAllowed(host), "封面域名 \(host) 应在白名单内")
        }
    }

    func testCoverAllowlistRejectsNonWhitelistedHosts() {
        // 复用 RetryAndPinningTests 的 allowlist fail-closed 骨架：
        // 非白名单域名在证书挑战阶段即被拒——封面会话与主 API 会话共用同一 delegate
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("evil.com"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("tracker.example.net"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("img-book-oss.guoguo.org.cn.evil.com"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("imge.kugou.com.evil.com"))
        // 形似域名（非点边界后缀）不匹配
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("evilguoguo.org.cn"))
        // 空串 fail-closed
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed(""))
    }

    func testCoverImageForNonAllowlistedHostReturnsNil() async {
        // 端到端兜底：非白名单主机取图必须返回 nil（不允许出图），
        // 无论网络层以 DNS 失败还是挑战拒绝收场，结果都应一致为 nil
        let url = URL(string: "https://definitely-not-allowlisted.example.invalid/cover.jpg")!
        let img = await CoverImageCache.shared.image(for: url)
        XCTAssertNil(img, "非白名单主机的封面请求必须失败并静默回落占位图")
    }

    // MARK: - P2-3 防盗链 Referer

    func testMakeRequestSetsRefererForGuoguoImgHost() {
        // guoguo.org.cn 防盗链图源：必须带 Referer（ting15 / ting08 共用该图床，referer 取其一）
        let url = URL(string: "https://img-book-oss.guoguo.org.cn/cover/1.jpg")!
        let req = CoverImageCache.makeRequest(for: url)
        let referer = req.value(forHTTPHeaderField: "Referer")
        XCTAssertNotNil(referer, "guoguo 图源封面请求必须带 Referer，否则 403 空白")
        XCTAssertTrue(referer == "https://m.ting15.com/" || referer == "https://www.ting08.com/",
                      "Referer 应为共用该图床的源站之一，实际 \(referer ?? "nil")")
    }

    func testMakeRequestSetsRefererForMekuiImgHosts() {
        let shuyinfm = CoverImageCache.makeRequest(
            for: URL(string: "https://shuyinfm.oss-cn-hangzhou.aliyuncs.com/2.jpg")!)
        XCTAssertEqual(shuyinfm.value(forHTTPHeaderField: "Referer"), "https://m.mekui.com/")

        let kugou = CoverImageCache.makeRequest(
            for: URL(string: "https://imge.kugou.com/3.jpg")!)
        XCTAssertEqual(kugou.value(forHTTPHeaderField: "Referer"), "https://m.mekui.com/")
    }

    func testMakeRequestOmitsRefererForNonRefererHosts() {
        // 非防盗链域名（听音主站）不设 Referer，避免无谓改写请求头
        let req = CoverImageCache.makeRequest(for: URL(string: "https://www.tingyou.fm/a.jpg")!)
        XCTAssertNil(req.value(forHTTPHeaderField: "Referer"))
    }

    func testMakeRequestPreservesURL() {
        let url = URL(string: "https://img-south-oss.guoguo.org.cn/c/i.png?sign=abc")!
        let req = CoverImageCache.makeRequest(for: url)
        XCTAssertEqual(req.url, url)
        XCTAssertEqual(req.httpMethod, "GET")
    }
}
