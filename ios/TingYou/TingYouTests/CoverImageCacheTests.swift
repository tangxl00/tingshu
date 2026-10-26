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

    /// build 20 必修 1 判别测试（guoguo 图床防盗链 referer）——build 36/37 听吧、
    /// 听十五相继下架后按 delisted 语义重写：MSRC 图床不再配置任何 referer
    /// （下架源的封面 403 属预期降级，源已不在 App 内可达）。
    func testMakeRequestRefererNilForMsrcHostsAfterDelisting() {
        let url = URL(string: "https://img-book-oss.guoguo.org.cn/cover/1.jpg")!
        XCTAssertNil(CoverImageCache.makeRequest(for: url).value(forHTTPHeaderField: "Referer"),
                     "无源上下文：MSRC 图床不再配 referer")
        XCTAssertNil(CoverImageCache.makeRequest(for: url, source: "ting15").value(forHTTPHeaderField: "Referer"),
                     "已下架源上下文：无 referer")
        XCTAssertNil(CoverImageCache.makeRequest(for: url, source: SourceRegistry.TINGYOU).value(forHTTPHeaderField: "Referer"),
                     "未知源上下文回落全局查找，注册表为空亦无 referer")
        let south = URL(string: "https://img-south-oss.guoguo.org.cn/cover/2.jpg")!
        XCTAssertNil(CoverImageCache.makeRequest(for: south, source: "ting08").value(forHTTPHeaderField: "Referer"))
    }

    func testMakeRequestOmitsRefererForGuoguoImgHostAfterDelisting() {
        // 无源上下文（旧行为兜底）：guoguo 图床在 ting15/ting08 全下架后无 referer
        let url = URL(string: "https://img-book-oss.guoguo.org.cn/cover/1.jpg")!
        let req = CoverImageCache.makeRequest(for: url)
        XCTAssertNil(req.value(forHTTPHeaderField: "Referer"),
                     "MSRC 源全下架后 guoguo 图床不再配 Referer")
    }

    func testMakeRequestOmitsRefererForMekuiImgHosts() {
        let shuyinfm = CoverImageCache.makeRequest(
            for: URL(string: "https://shuyinfm.oss-cn-hangzhou.aliyuncs.com/2.jpg")!)
        XCTAssertNil(shuyinfm.value(forHTTPHeaderField: "Referer"),
                     "书音FM 下架后其图床不再配 Referer")

        let kugou = CoverImageCache.makeRequest(
            for: URL(string: "https://imge.kugou.com/3.jpg")!)
        XCTAssertNil(kugou.value(forHTTPHeaderField: "Referer"))
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
