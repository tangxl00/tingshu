import XCTest
@testable import TingYou

/// build 42 · 任务二：悦听 cookie path 嫌疑的单测裁决（纯逻辑，无网络请求）。
///
/// 背景：验证滑块通过后服务器 Set-Cookie（含 be_captcha_token），经
/// YtysxsCookieSync 全量同步进 HTTPCookieStorage.shared；但 fetchHtml 若用
/// cookies(for:) 取域内 cookie，其严格 RFC 6265 path 匹配会把 path 非根
///（如 /wp-admin/——admin-ajax.php 所在路径）的 cookie 对搜索 URL
///（path=/）静默漏掉 → 请求没带 → 站点仍拦截（用户「验证过了但搜索仍被拦」
/// 的剩余唯一嫌疑）。本组测试：
/// ① testStoragePathMatchingAdjudication——向真实 HTTPCookieStorage 注入唯一
///    命名的探针 cookie（测后清理），裁决 URLSession 自身的 path 匹配行为。
///    若「path=/wp-admin/ 应被漏掉」断言失败，说明 path 假设被证伪——
///    该失败本身即为证据（结果二选一，都有结论）。
/// ② mergedCookieHeader 纯函数组——锁定 build 42 修复后的合并行为：
///    domain 匹配放宽（dotless / 带点域均命中 www 子域）+ path 放宽
///    （域内 cookie 一律携带）+ Keychain token 兜底去重。
final class YtysxsCookieMatchingTests: XCTestCase {

    private func makeCookie(name: String, value: String, domain: String, path: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ])!
    }

    /// 搜索 URL 与 YtysxsAdapter.search 实际拼出的形态一致（path=/）
    private let searchURL = URL(string: "https://www.ytysxs.com/?s=%E5%B0%81%E7%A5%9E")!

    // ---- ① 真实 storage path 匹配裁决（探针名唯一避免污染，defer 清理） ----

    func testStoragePathMatchingAdjudication() throws {
        let storage = HTTPCookieStorage.shared
        // 探针 1：path=/wp-admin/（admin-ajax.php Set-Cookie 场景）——按 RFC 6265
        // path-match 规则，请求 path=/ 不匹配 cookie path=/wp-admin/，应被漏掉。
        let nonRoot = makeCookie(name: "b42_path_probe_nonroot", value: "1",
                                 domain: ".ytysxs.com", path: "/wp-admin/")
        // 探针 2（对照）：path=/ —— 应正常命中。
        let root = makeCookie(name: "b42_path_probe_root", value: "1",
                              domain: ".ytysxs.com", path: "/")
        storage.setCookie(nonRoot)
        storage.setCookie(root)
        defer {
            storage.deleteCookie(nonRoot)
            storage.deleteCookie(root)
        }
        let got = storage.cookies(for: searchURL) ?? []
        XCTAssertTrue(got.contains { $0.name == "b42_path_probe_root" },
                      "对照探针（path=/）未命中——storage 域匹配环境异常，检查本测试前置条件")
        XCTAssertFalse(got.contains { $0.name == "b42_path_probe_nonroot" },
                      "path=/wp-admin/ 的 cookie 竟被 cookies(for:) 返回——path 假设被证伪（此失败本身即为证据）")
    }

    // ---- ② mergedCookieHeader 纯函数（build 42 修复行为锁定） ----

    func testMergeIncludesNonRootPathDomainCookies() throws {
        // path=/wp-admin/ 的 token 与会话 cookie：修复后应全部携带（修复点）
        let cookies = [
            makeCookie(name: "be_captcha_token", value: "tokA", domain: ".ytysxs.com", path: "/wp-admin/"),
            makeCookie(name: "PHPSESSID", value: "sess1", domain: ".ytysxs.com", path: "/wp-admin/"),
            makeCookie(name: "wordpress_sec", value: "w1", domain: ".ytysxs.com", path: "/"),
        ]
        let header = YtysxsAdapter.mergedCookieHeader(url: searchURL,
                                                      storageCookies: cookies,
                                                      keychainHeaderValue: "be_captcha_token=keychainTok")
        let h = try XCTUnwrap(header)
        XCTAssertTrue(h.contains("be_captcha_token=tokA"), "path 非根的 token 应被携带（修复点）")
        XCTAssertFalse(h.contains("keychainTok"), "storage 已有 token 时 Keychain 不重复注入")
        XCTAssertTrue(h.contains("PHPSESSID=sess1"), "path 非根的会话 cookie 应被携带（修复点）")
        XCTAssertTrue(h.contains("wordpress_sec=w1"), "path=/ 的 cookie 正常携带")
    }

    func testMergeDomainVariantsAllMatchWWWHost() {
        // dotless 域 / 带点域 / 精确 www 域，三种形态对 www.ytysxs.com 均命中
        let cookies = [
            makeCookie(name: "a", value: "1", domain: "ytysxs.com", path: "/"),
            makeCookie(name: "b", value: "2", domain: ".ytysxs.com", path: "/wp-admin/"),
            makeCookie(name: "c", value: "3", domain: "www.ytysxs.com", path: "/"),
        ]
        let header = YtysxsAdapter.mergedCookieHeader(url: searchURL,
                                                      storageCookies: cookies,
                                                      keychainHeaderValue: nil)
        XCTAssertEqual(header, "a=1; b=2; c=3")
    }

    func testMergeExcludesForeignDomainCookies() {
        // 异域与伪后缀域一律排除
        let cookies = [
            makeCookie(name: "sess", value: "x", domain: ".example.com", path: "/"),
            makeCookie(name: "sess2", value: "y", domain: "t.ytysxs.com.evil.net", path: "/"),
        ]
        let header = YtysxsAdapter.mergedCookieHeader(url: searchURL,
                                                      storageCookies: cookies,
                                                      keychainHeaderValue: nil)
        XCTAssertNil(header)
    }

    func testMergeKeychainFallbackWhenStorageEmpty() {
        let header = YtysxsAdapter.mergedCookieHeader(url: searchURL,
                                                      storageCookies: [],
                                                      keychainHeaderValue: "be_captcha_token=k1")
        XCTAssertEqual(header, "be_captcha_token=k1")
    }

    func testMergeKeychainFallbackWhenOnlyForeignCookies() {
        // storage 里只有异域 cookie → 视为空，Keychain token 兜底注入
        let foreign = makeCookie(name: "PHPSESSID", value: "s", domain: ".example.com", path: "/")
        let header = YtysxsAdapter.mergedCookieHeader(url: searchURL,
                                                      storageCookies: [foreign],
                                                      keychainHeaderValue: "be_captcha_token=k1")
        XCTAssertEqual(header, "be_captcha_token=k1")
    }

    func testMergeReturnsNilWhenNoCookiesAnywhere() {
        XCTAssertNil(YtysxsAdapter.mergedCookieHeader(url: searchURL,
                                                      storageCookies: [],
                                                      keychainHeaderValue: nil))
    }

    func testDomainMatchesDirectCases() {
        XCTAssertTrue(YtysxsAdapter.domainMatches(host: "www.ytysxs.com", cookieDomain: ".ytysxs.com"))
        XCTAssertTrue(YtysxsAdapter.domainMatches(host: "www.ytysxs.com", cookieDomain: "ytysxs.com"))
        XCTAssertTrue(YtysxsAdapter.domainMatches(host: "www.ytysxs.com", cookieDomain: "www.ytysxs.com"))
        XCTAssertFalse(YtysxsAdapter.domainMatches(host: "www.ytysxs.com", cookieDomain: ".example.com"))
        XCTAssertFalse(YtysxsAdapter.domainMatches(host: "www.ytysxs.com", cookieDomain: "t.ytysxs.com"))
        XCTAssertFalse(YtysxsAdapter.domainMatches(host: "www.ytysxs.com", cookieDomain: ""))
        // 大小写不敏感
        XCTAssertTrue(YtysxsAdapter.domainMatches(host: "WWW.YTYSXS.com", cookieDomain: ".Ytysxs.COM"))
    }
}
