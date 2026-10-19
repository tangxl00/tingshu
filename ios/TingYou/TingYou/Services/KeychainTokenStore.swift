import Foundation
import Security

/// 悦听有声书 be_captcha_token 持久化存储（P0-4 / P1-2）。
///
/// - token 主体存 iOS Keychain（kSecClassGenericPassword，SecItemAdd / SecItemCopyMatching / SecItemDelete），
///   绝不落 UserDefaults 明文；
/// - 过期元数据（保存时间戳 + Max-Age）为非敏感数据，存 UserDefaults 便于单测与诊断；
/// - 24h（86400s）有效，读时自检过期，过期返回 nil 并清理 Keychain 条目；
/// - isTokenValid 为纯函数，XCTest 可直接覆盖过期边界。
final class KeychainTokenStore {

    private let service: String
    private let account: String
    private let defaults: UserDefaults

    init(service: String = "com.tingyou.app.ios.ytysxs",
         account: String = "be_captcha_token",
         defaults: UserDefaults = .standard) {
        self.service = service
        self.account = account
        self.defaults = defaults
    }

    // MARK: - 过期元数据（UserDefaults，非敏感）

    private var savedAtKey: String { "ytysxs_\(account)_saved_at" }
    private var maxAgeKey: String { "ytysxs_\(account)_max_age" }

    static let defaultMaxAgeSec: TimeInterval = 86400 // 24h

    /// 当前是否持有有效（未过期）的验证 token
    func hasValidToken() -> Bool {
        load() != nil
    }

    /// 当前有效 cookie 值（含 be_captcha_token= 前缀，供请求头直接注入）
    func cookieHeaderValue() -> String? {
        guard let token = load() else { return nil }
        return "be_captcha_token=\(token)"
    }

    /// 保存验证后的 token（WKWebView httpCookieStore 捕获后调用）
    func save(token: String, maxAgeSec: TimeInterval = KeychainTokenStore.defaultMaxAgeSec) {
        let baseQuery = Self.baseQuery(service: service, account: account)
        let addQuery = baseQuery.merging([
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]) { _, new in new }
        SecItemDelete(baseQuery as CFDictionary)
        SecItemAdd(addQuery as CFDictionary, nil)
        defaults.set(Date().timeIntervalSince1970, forKey: savedAtKey)
        defaults.set(maxAgeSec, forKey: maxAgeKey)
    }

    /// 读取有效 token；过期或缺失返回 nil（并顺手清理过期条目）
    func load() -> String? {
        let savedAt = defaults.double(forKey: savedAtKey)
        let maxAge = defaults.double(forKey: maxAgeKey)
        let now = Date().timeIntervalSince1970
        guard KeychainTokenStore.isTokenValid(token: keychainRead(),
                                               savedAtMs: savedAt,
                                               maxAgeSec: maxAge,
                                               nowSec: now) else {
            if savedAt > 0 { clear() }
            return nil
        }
        return keychainRead()
    }

    /// 清除 token（登出 / 过期 / 验证失效时）
    func clear() {
        SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        defaults.removeObject(forKey: savedAtKey)
        defaults.removeObject(forKey: maxAgeKey)
    }

    // MARK: - 纯函数（JVM/XCTest 可测的过期判定，语义与安卓 YtysxsCookieStore.isTokenValid 一致）

    static func isTokenValid(token: String?, savedAtMs: Double, maxAgeSec: Double, nowSec: Double) -> Bool {
        guard let token = token, !token.isEmpty, savedAtMs > 0, maxAgeSec > 0 else { return false }
        return nowSec - savedAtMs < maxAgeSec
    }

    // MARK: - Keychain 读写

    private func keychainRead() -> String? {
        let query = Self.baseQuery(service: service, account: account).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
