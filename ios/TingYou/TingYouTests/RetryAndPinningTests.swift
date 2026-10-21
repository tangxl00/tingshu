import XCTest
@testable import TingYou

/// P0-5 重试策略 + P1-1 域名后缀 pinning 白名单的回归测试。
final class RetryAndPinningTests: XCTestCase {

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

    func testMekuiRetryConfigMatchesAndroidBaseline() {
        XCTAssertEqual(RetryConfig.mekui.maxRetries, 2)
        XCTAssertEqual(RetryConfig.mekui.backoffSecs, [2.5, 8.0])
    }

    func testBackoffClampsToLastEntry() {
        let cfg = RetryConfig.mekui
        XCTAssertEqual(cfg.backoff(forAttempt: 0), 2.5)
        XCTAssertEqual(cfg.backoff(forAttempt: 1), 8.0)
        XCTAssertEqual(cfg.backoff(forAttempt: 5), 8.0)
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
        // 判别力：旧实现传输层错误 continue 直跑、无等待——elapsed 断言在旧实现下必失败
        var calls = 0
        RetryStubURLProtocol.handler = { _ in
            calls += 1
            return (200, Data("ok".utf8))
        }
        RetryStubURLProtocol.errorOnce = URLError(.notConnectedToInternet)
        let client = APIClient(session: RetryStubURLProtocol.makeSession())
        let cfg = RetryConfig(maxRetries: 1, backoffSecs: [1.5], transportBackoffSecs: [0.3])
        let request = URLRequest(url: URL(string: "https://m.ting15.com/")!)
        let start = Date()
        let (data, resp) = try await client.execute(request, retry: cfg)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(calls, 2, "传输层错误应重试一次后成功")
        XCTAssertGreaterThanOrEqual(elapsed, 0.25, "重试前必须退避等待（0.3s 档），旧实现直跑不等待")
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
        XCTAssertFalse(RetryConfig.isConnectionError(AntibotException(keyword: "三体")))
        // 固定重试预算：2 次重试（共 3 次尝试），三种 config 一致
        XCTAssertEqual(RetryConfig.standard.connectionMaxRetries, 2)
        XCTAssertEqual(RetryConfig.msrc.connectionMaxRetries, 2)
        XCTAssertEqual(RetryConfig.mekui.connectionMaxRetries, 2)
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

    func testAllowlistExactDomains() {
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("file.hgeuz.cn"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("m.ting15.com"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("mp3.ytysxs.top"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("api.aikeu.com"))
        // 精确域名的子域不在白名单内（仅 5 个后缀域支持子域）
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("x.file.hgeuz.cn"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("sub.m.ting15.com"))
    }

    func testAllowlistCaseInsensitive() {
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("API.TINGYOU.FM"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("WWW.TING08.COM"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("EVIL.TINGYOU.FM.EVIL.COM"))
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
