import XCTest
@testable import TingYou

/// P0-4 / P1-2：be_captcha_token 的 Keychain 存储与 24h 过期语义。
final class KeychainTokenStoreTests: XCTestCase {

    /// 每个用例独立的 service + UserDefaults suite，避免 Keychain / defaults 串扰。
    private func makeStore() -> (KeychainTokenStore, UserDefaults) {
        let suiteName = "ytysxs-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = KeychainTokenStore(service: "com.tingyou.app.ios.tests.\(UUID().uuidString)",
                                       account: "be_captcha_token",
                                       defaults: defaults)
        return (store, defaults)
    }

    // MARK: - 纯函数：isTokenValid

    func testTokenValidityRequiresNonEmptyToken() {
        XCTAssertFalse(KeychainTokenStore.isTokenValid(token: nil, savedAtMs: 1000, maxAgeSec: 86400, nowSec: 2000))
        XCTAssertFalse(KeychainTokenStore.isTokenValid(token: "", savedAtMs: 1000, maxAgeSec: 86400, nowSec: 2000))
    }

    func testTokenValidityRequiresPositiveTimestamps() {
        XCTAssertFalse(KeychainTokenStore.isTokenValid(token: "tok", savedAtMs: 0, maxAgeSec: 86400, nowSec: 2000))
        XCTAssertFalse(KeychainTokenStore.isTokenValid(token: "tok", savedAtMs: 1000, maxAgeSec: 0, nowSec: 2000))
        XCTAssertFalse(KeychainTokenStore.isTokenValid(token: "tok", savedAtMs: -1, maxAgeSec: 86400, nowSec: 2000))
    }

    func testTokenValidWithinMaxAge() {
        XCTAssertTrue(KeychainTokenStore.isTokenValid(token: "tok", savedAtMs: 1000, maxAgeSec: 86400, nowSec: 2000))
        XCTAssertTrue(KeychainTokenStore.isTokenValid(token: "tok", savedAtMs: 1000, maxAgeSec: 86400, nowSec: 86300 + 1000))
    }

    func testTokenExpiredAfterMaxAge() {
        XCTAssertFalse(KeychainTokenStore.isTokenValid(token: "tok", savedAtMs: 1000, maxAgeSec: 86400, nowSec: 86401 + 1000))
        XCTAssertFalse(KeychainTokenStore.isTokenValid(token: "tok", savedAtMs: 1000, maxAgeSec: 86400, nowSec: 86400 + 1000))
    }

    // MARK: - Keychain 读写闭环（模拟器内 SecItem 可用）

    func testSaveLoadRoundtrip() throws {
        let (store, _) = makeStore()
        XCTAssertNil(store.load(), "初始状态无 token")
        store.save(token: "abc123captcha")
        XCTAssertEqual(store.load(), "abc123captcha")
        XCTAssertTrue(store.hasValidToken())
        store.clear()
    }

    func testLoadReturnsNilAfterClear() {
        let (store, _) = makeStore()
        store.save(token: "tok-xyz")
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasValidToken())
        XCTAssertNil(store.cookieHeaderValue())
    }

    func testCookieHeaderValueFormat() {
        let (store, _) = makeStore()
        store.save(token: "abc123captcha")
        XCTAssertEqual(store.cookieHeaderValue(), "be_captcha_token=abc123captcha")
        store.clear()
    }

    func testExpiredTokenAutoClears() {
        let (store, defaults) = makeStore()
        store.save(token: "tok-old")
        // 把保存时间拨回 25h 前：超出 24h Max-Age，load 应判定过期并清理
        defaults.set(Date().timeIntervalSince1970 - 90000, forKey: "ytysxs_be_captcha_token_saved_at")
        defaults.set(86400.0, forKey: "ytysxs_be_captcha_token_max_age")
        XCTAssertNil(store.load(), "过期 token 不应返回")
        XCTAssertFalse(store.hasValidToken())
        // 已被自动清理：defaults 元数据被移除
        XCTAssertEqual(defaults.double(forKey: "ytysxs_be_captcha_token_saved_at"), 0)
    }

    func testDefaultMaxAgeIs24Hours() {
        XCTAssertEqual(KeychainTokenStore.defaultMaxAgeSec, 86400)
    }
}
