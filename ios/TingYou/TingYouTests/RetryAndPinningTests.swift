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

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RetryStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
