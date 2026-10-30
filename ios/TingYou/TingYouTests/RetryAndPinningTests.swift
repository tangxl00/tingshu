import XCTest
@testable import TingYou

/// P0-5 重试策略 + P1-1 域名后缀 pinning 白名单的回归测试。
final class RetryAndPinningTests: XCTestCase {

    // build 36 返修（CI #5 加固）：RetryStubURLProtocol 的四个静态桩（handler /
    // errorOnce / errorAlways / callCounter）为全局单槽，此前各用例只在 Happy Path
    // 尾部手工清理——一旦用例中途 throw（如 catch 类型不匹配），静态态即泄漏到
    // 同进程后续用例（errorAlways 残留会让后续用例莫名多退避多失败）。
    // 统一 setUp/tearDown 全量清态，消除跨用例串扰面。
    override func setUp() {
        super.setUp()
        RetryStubURLProtocol.handler = nil
        RetryStubURLProtocol.errorOnce = nil
        RetryStubURLProtocol.errorAlways = nil
        RetryStubURLProtocol.callCounter = nil
    }

    override func tearDown() {
        RetryStubURLProtocol.handler = nil
        RetryStubURLProtocol.errorOnce = nil
        RetryStubURLProtocol.errorAlways = nil
        RetryStubURLProtocol.callCounter = nil
        super.tearDown()
    }

    // MARK: - HttpRetryPolicy

    func testRetryableStatusesAreGatewayClassOnly() {
        XCTAssertTrue(HttpRetryPolicy.isRetryable(502))
        XCTAssertTrue(HttpRetryPolicy.isRetryable(503))
        XCTAssertTrue(HttpRetryPolicy.isRetryable(504))
    }

    func testNonGatewayStatusesAreNotRetryable() {
        XCTAssertFalse(HttpRetryPolicy.isRetryable(200))
        XCTAssertFalse(HttpRetryPolicy.isRetryable(201))
        XCTAssertFalse(HttpRetryPolicy.isRetryable(301))
        XCTAssertFalse(HttpRetryPolicy.isRetryable(404))
        XCTAssertFalse(HttpRetryPolicy.isRetryable(500))
        XCTAssertFalse(HttpRetryPolicy.isRetryable(0))
    }

    func testRetryableSetContentsExactly() {
        XCTAssertEqual(HttpRetryPolicy.retryableStatuses, [502, 503, 504])
    }

    // MARK: - RetryConfig（安卓基线对齐）

    func testMsrcRetryConfigMatchesAndroidBaseline() {
        XCTAssertEqual(RetryConfig.msrc.maxRetries, 1)
        XCTAssertEqual(RetryConfig.msrc.backoffSecs, [1.5])
    }

    /// build 51（音源残留）：书音FM 下架 → `RetryConfig.mekui` 删除，
    /// 该用例由「mekui 基线」改为「退避阶梯钳制」通用语义断言（用多档自定义 config）。
    func testBackoffClampsToLastEntry() {
        let cfg = RetryConfig(maxRetries: 2, backoffSecs: [2.5, 8.0])
        XCTAssertEqual(cfg.backoff(forAttempt: 0), 2.5)
        XCTAssertEqual(cfg.backoff(forAttempt: 1), 8.0)
        XCTAssertEqual(cfg.backoff(forAttempt: 5), 8.0)
    }

    /// build 51：下架源的专用重试配置不得残留（防「删适配器忘删配置」复燃）。
    func testDelistedSourceRetryConfigRemoved() {
        // 仅保留 msrc / standard 两档（mekui 随书音FM 适配器一并删除）
        XCTAssertEqual(RetryConfig.msrc.maxRetries, 1)
        XCTAssertEqual(RetryConfig.standard.maxRetries, 1)
    }

    func testBackoffEmptyDefaultsToOne() {
        let cfg = RetryConfig(maxRetries: 0, backoffSecs: [])
        XCTAssertEqual(cfg.backoff(forAttempt: 0), 1.0)
    }

    // MARK: - build 20 必修 5：传输层错误重试退避

    func testTransportBackoffLadderValues() {
        let cfg = RetryConfig.standard
        XCTAssertEqual(cfg.transportBackoffSecs, [0.5, 1.0, 2.0], "0.5s/1s/2s 指数退避阶梯")
        XCTAssertEqual(cfg.transportBackoff(forAttempt: 0), 0.5)
        XCTAssertEqual(cfg.transportBackoff(forAttempt: 1), 1.0)
        XCTAssertEqual(cfg.transportBackoff(forAttempt: 2), 2.0)
        XCTAssertEqual(cfg.transportBackoff(forAttempt: 5), 2.0, "阶梯用尽后取最后一档")
    }

    func testTransportErrorRetriesWithBackoffThenSucceeds() async throws {
        // 判别力：旧实现传输层错误 continue 直跑、无等待——elapsed 断言在旧实现下必失败。
        // build 36 返修（CI #5 真实根因）：原实现 calls 用 handler 闭包计数——errorOnce
        // 注入失败的那次首发请求走 didFailWithError 分支、根本不触达 handler，重试成功后
        // handler 只被调 1 次，断言 calls==2 确定性失败（三轮 0.404s/0.529s/1.455s 均败
        // 于此；时长波动=0.3s 退避 + CI 负载，elapsed 断言本身一直通过）。非静态桩串扰、
        // 非 URLProtocol 桩 CI 行为差异。改用 callCounter 口径（每次 startLoading 必调、
        // 含注入失败的首发），与 testConnectionLostRetriesThenSucceeds 对齐。
        var calls = 0
        RetryStubURLProtocol.callCounter = { calls += 1 }
        RetryStubURLProtocol.handler = { _ in (200, Data("ok".utf8)) }
        RetryStubURLProtocol.errorOnce = URLError(.notConnectedToInternet)
        let client = APIClient(session: RetryStubURLProtocol.makeSession())
        let cfg = RetryConfig(maxRetries: 1, backoffSecs: [1.5], transportBackoffSecs: [0.3])
        let request = URLRequest(url: URL(string: "https://m.ting15.com/")!)
        let start = Date()
        let (data, resp) = try await client.execute(request, retry: cfg)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(calls, 2, "传输层错误应退避后重试一次成功（共 2 次请求，含注入失败的首发）")
        XCTAssertGreaterThanOrEqual(elapsed, 0.25, "重试前必须退避等待（0.3s 档），旧实现直跑不等待")
        RetryStubURLProtocol.callCounter = nil
        RetryStubURLProtocol.handler = nil
    }

    func testTransportErrorSucceedsImmediatelyWithoutDelay() async throws {
        // 首发成功不引入任何退避延迟（对用户可感知的首次请求无感）
        RetryStubURLProtocol.handler = { _ in (200, Data("ok".utf8)) }
        let client = APIClient(session: RetryStubURLProtocol.makeSession())
        let request = URLRequest(url: URL(string: "https://m.ting15.com/")!)
        let start = Date()
        _ = try await client.execute(request)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25, "首发成功不应有任何退避延迟")
        RetryStubURLProtocol.handler = nil
    }

    // MARK: - APIClient.execute 端到端重试（stub 协议注入）

    func testExecuteRetriesOn502ThenSucceeds() async throws {
        var calls = 0
        RetryStubURLProtocol.handler = { _ in
            calls += 1
            return calls == 1 ? (502, Data()) : (200, Data("ok".utf8))
        }
        let client = APIClient(session: RetryStubURLProtocol.makeSession())
        let req = URLRequest(url: URL(string: "https://tingyou.fm/ping")!)
        let (data, resp) = try await client.execute(req)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(calls, 2, "502 应退避后重试一次")
        RetryStubURLProtocol.handler = nil
    }

    func testExecuteFailsAfterExhaustedRetries() async {
        var calls = 0
        RetryStubURLProtocol.handler = { _ in
            calls += 1
            return (503, Data())
        }
        let client = APIClient(session: RetryStubURLProtocol.makeSession())
        let req = URLRequest(url: URL(string: "https://tingyou.fm/ping")!)
        do {
            _ = try await client.execute(req)
            XCTFail("重试耗尽后应抛错")
        } catch {
            XCTAssertEqual(calls, 2, "standard 策略共 2 次请求（首发 + 1 次重试）")
        }
        RetryStubURLProtocol.handler = nil
    }

    func testExecuteDoesNotRetryOn404() async throws {
        var calls = 0
        RetryStubURLProtocol.handler = { _ in
            calls += 1
            return (404, Data())
        }
        let client = APIClient(session: RetryStubURLProtocol.makeSession())
        let req = URLRequest(url: URL(string: "https://tingyou.fm/missing")!)
        do {
            _ = try await client.execute(req)
            XCTFail("404 应直接失败")
        } catch {
            XCTAssertEqual(calls, 1, "404 不可重试，只应请求一次")
        }
        RetryStubURLProtocol.handler = nil
    }

    // MARK: - build 22 r2 · 连接级错误自动重试（真机反馈「The network connection was lost.」）

    func testConnectionErrorCodeSetIsExactlyConnectionClass() {
        // 判别力：集合恰为六类连接级错误——多纳一个（如 cancelled）或漏一个都会被断出来
        // build 24（P2-1）：补入 DNS 瞬时错误 -1003 / -1006，集合从四类扩为六类
        XCTAssertEqual(RetryConfig.connectionErrorCodes, [
            .networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet,
            .cannotFindHost, .dnsLookupFailed,
        ])
        XCTAssertTrue(RetryConfig.isConnectionError(URLError(.networkConnectionLost)))
        XCTAssertTrue(RetryConfig.isConnectionError(URLError(.timedOut)))
        XCTAssertTrue(RetryConfig.isConnectionError(URLError(.cannotConnectToHost)))
        XCTAssertTrue(RetryConfig.isConnectionError(URLError(.notConnectedToInternet)))
        XCTAssertTrue(RetryConfig.isConnectionError(URLError(.cannotFindHost)), "build 24：DNS 解析失败应纳入连接重试")
        XCTAssertTrue(RetryConfig.isConnectionError(URLError(.dnsLookupFailed)), "build 24：DNS 查找失败应纳入连接重试")
        // 非连接级 URLError 与非 URLError 一律不重试
        XCTAssertFalse(RetryConfig.isConnectionError(URLError(.cancelled)))
        XCTAssertFalse(RetryConfig.isConnectionError(URLError(.badURL)))
        // build 45 · 反馈 3：AntibotException 类型随悦听摘除整体删除（此处不再可构造）
        // 固定重试预算：2 次重试（共 3 次尝试），三种 config 一致
        XCTAssertEqual(RetryConfig.standard.connectionMaxRetries, 2)
        XCTAssertEqual(RetryConfig.msrc.connectionMaxRetries, 2)
    }

    func testConnectionLostRetriesThenSucceeds() async throws {
        // 首发连接被断（-1005）→ 新建连接重试 → 成功；用户无感恢复。
        // 计数用 callCounter（每次 startLoading 必调，含失败请求），口径无歧义。
        var calls = 0
        RetryStubURLProtocol.callCounter = { calls += 1 }
        RetryStubURLProtocol.handler = { _ in (200, Data("ok".utf8)) }
        RetryStubURLProtocol.errorOnce = URLError(.networkConnectionLost)
        let client = APIClient(session: RetryStubURLProtocol.makeSession())
        let cfg = RetryConfig(maxRetries: 1, backoffSecs: [1.5], transportBackoffSecs: [0.05])
        let req = URLRequest(url: URL(string: "https://m.ting08.com/")!)
        let (data, resp) = try await client.execute(req, retry: cfg)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(calls, 2, "连接被断后应新建连接重试一次后成功（共 2 次请求）")
        RetryStubURLProtocol.callCounter = nil
        RetryStubURLProtocol.handler = nil
    }

    func testConnectionRetryExhaustedSurfacesUpgradedMessage() async throws {
        // 连续 3 次连接失败（0.5s/1s 退避耗尽）→ 抛升级文案，不再裸抛英文原文
        RetryStubURLProtocol.errorAlways = URLError(.networkConnectionLost)
        var calls = 0
        RetryStubURLProtocol.callCounter = { calls += 1 }
        let client = APIClient(session: RetryStubURLProtocol.makeSession())
        let cfg = RetryConfig(maxRetries: 1, backoffSecs: [1.5], transportBackoffSecs: [0.05, 0.05])
        let req = URLRequest(url: URL(string: "https://m.ting08.com/")!)
        do {
            _ = try await client.execute(req, retry: cfg)
            XCTFail("3 次连接失败后应抛错")
        } catch let err as ConnectionRetryExhaustedError {
            XCTAssertEqual(calls, 3, "共 3 次尝试（首发 + 2 次重试）")
            XCTAssertEqual(err.localizedDescription,
                           "网络连接中断（已自动重试仍失败），请检查网络后重试",
                           "耗尽后必须是可诊断的升级文案")
        }
        RetryStubURLProtocol.errorAlways = nil
        RetryStubURLProtocol.callCounter = nil
    }

    func testNonConnectionErrorIsNotRetried() async throws {
        // 非连接级错误（用户取消）不重试——不误伤既有闭环
        var calls = 0
        RetryStubURLProtocol.callCounter = { calls += 1 }
        RetryStubURLProtocol.errorOnce = URLError(.cancelled)
        let client = APIClient(session: RetryStubURLProtocol.makeSession())
        let req = URLRequest(url: URL(string: "https://m.ting08.com/")!)
        do {
            _ = try await client.execute(req)
            XCTFail("取消错误应直接抛出")
        } catch let err as URLError {
            XCTAssertEqual(err.code, .cancelled)
        }
        XCTAssertEqual(calls, 1, "非连接级错误只应请求一次，不得重试")
        RetryStubURLProtocol.callCounter = nil
    }

    // MARK: - PinnedDomainAllowlist（P1-1：与安卓 includeSubdomains 语义对等）

    func testAllowlistSuffixDomainMatchesSubdomains() {
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("tingyou.fm"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("api.tingyou.fm"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("a.b.kuwo.cn"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("node03.ctyun.cn"))
    }

    func testAllowlistRejectsLookalikeDomains() {
        // 后缀必须是域名边界（点开头），eviltingyou.fm 不匹配 .tingyou.fm
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("eviltingyou.fm"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("tingyou.fm.evil.com"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("notkuwo.cn"))
    }

    /// build 51（质检必修 · 音源残留）：断言由「旧精确域仍放行」反转为「已下架源精确域必须摘除」，
    /// 并对在役精确域保留放行断言（收敛不能过头）。
    func testAllowlistExactDomains() {
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("file.hgeuz.cn"), "听友FM 文件域仍在役")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("imge.kugou.com"), "封面域仍在役")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("www.yitingshu.com"), "易听书站必须放行")
        // 已下架源（听十五 / 书音FM 及其图床音频域）必须摘除
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("m.ting15.com"), "听十五已下架")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("api.aikeu.com"), "书音FM 图床已下架")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("mp3.aikeu.com"), "书音FM 音频域已下架")
        // 精确域名的子域不在白名单内（仅后缀域支持子域）
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("x.file.hgeuz.cn"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("sub.www.yitingshu.com"))
    }

    func testAllowlistCaseInsensitive() {
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("API.TINGYOU.FM"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("WWW.YITINGSHU.COM"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("AOD.COS.TX.XMCDN.COM"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("EVIL.TINGYOU.FM.EVIL.COM"))
        // build 51：已下架源的大小写变体同样不得放行
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("WWW.TING08.COM"), "听吧已下架")
    }

    func testAllowlistRejectsUnknownHostsFailClosed() {
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("evil.com"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("tracker.example.net"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed(""))
    }
}

/// 注入 APIClient 的 URLProtocol stub：按 handler 返回 (statusCode, body)。
final class RetryStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    /// build 20 必修 5：下一次请求注入一次传输层错误（用后自动清空，模拟瞬时断网）
    nonisolated(unsafe) static var errorOnce: Error?
    /// build 22 r2：每次请求都注入该错误（连接重试耗尽场景），测试后必须清空
    nonisolated(unsafe) static var errorAlways: Error?
    /// build 22 r2：请求计数回调（每次 startLoading 必调，含注入错误的请求）
    nonisolated(unsafe) static var callCounter: (() -> Void)?
    /// build 52 · #140 条件 3：按请求**定向**注入传输层错误（`errorOnce` 只能命中
    /// 「下一条任意请求」，无法表达「某个端点失败、其它端点正常」；而 syncNow 的
    /// 真实场景正是 push 回 40003、refresh 遇网络瞬态、pull 正常）。
    /// 闭包返回非 nil 即让该请求失败；返回 nil 则继续走 handler。
    nonisolated(unsafe) static var errorMatcher: ((URLRequest) -> Error?)?

    /// build 52 · 四条静态槽一次性清态（原各用例手工逐个置 nil，漏一个就跨用例串扰）
    static func reset() {
        handler = nil
        errorOnce = nil
        errorAlways = nil
        callCounter = nil
        errorMatcher = nil
    }

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RetryStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.callCounter?()
        if let err = Self.errorOnce {
            Self.errorOnce = nil
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        if let err = Self.errorAlways {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        if let err = Self.errorMatcher?(request) {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, data) = handler(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
