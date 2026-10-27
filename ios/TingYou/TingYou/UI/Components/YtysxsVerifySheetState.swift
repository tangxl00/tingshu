import Foundation

/// build 38 · 反馈 2：悦听验证 sheet 的加载状态机（纯逻辑、无 UIKit 依赖，可单测）。
///
/// 背景：用户第二次反馈「验证页加载不出来」。站点侧取证结论是站点可达、不封
/// WebView UA——问题在客户端 WebView 链路。此前 sheet 的加载/失败/超时/重试
/// 状态散落在 isLoading / loadErrorText / retryToken 三个 @State 里，转换规则
/// 隐式且不可测；本类型把转换收敛为显式事件 → 状态迁移，供 sheet 驱动 UI，
/// 单测覆盖全部合法/非法迁移（测试环境无法跑真机 WKWebView，状态机必须可测）。
enum VerifyLoadPhase: Equatable {
    /// 未加载（初始 / 加载完成后的静默态）
    case idle
    /// 加载中，progress ∈ [0,1]（nil = 未知进度，WKWebView estimatedProgress 未回包）
    case loading(progress: Double?)
    /// 加载失败（网络错误 / 网页进程终止且自动恢复失败）
    case failed(reason: String)
    /// 加载超时（25 秒兜底触发，慢网络/连接挂起无导航回包）
    case timedOut
}

struct VerifyLoadStateMachine: Equatable {
    /// 当前阶段（唯一事实源，UI 全部由 phase 派生）
    private(set) var phase: VerifyLoadPhase = .idle
    /// 重试次数（限观测/日志，不设上限——重试由用户手动点击触发）
    private(set) var retryCount = 0

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    /// 开始一次加载（load() 触发 / 重试重建后新一轮）
    mutating func start() {
        phase = .loading(progress: nil)
    }

    /// 进度回包（WKWebView estimatedProgress KVO）——仅在 loading 态接受，
    /// 夹取到 [0,1]；导航完成后的迟到进度回包不复活加载态。
    mutating func updateProgress(_ raw: Double) {
        guard case .loading = phase else { return }
        phase = .loading(progress: min(max(raw, 0), 1))
    }

    /// 导航完成（didFinish）——离开加载态，静默 idle（结果由 token 捕获路径另行回调）
    mutating func finish() {
        phase = .idle
    }

    /// 加载失败（didFail / didFailProvisionalNavigation 非 Cancelled / 进程终止自动恢复失败）
    mutating func fail(_ reason: String) {
        phase = .failed(reason: reason)
    }

    /// 超时兜底触发——仅在仍处于 loading 态时生效（导航已回包则迟到的超时不覆盖）
    mutating func timeout() {
        guard case .loading = phase else { return }
        phase = .timedOut
    }

    /// 用户点击重试：仅 failed / timedOut 可重试（loading 中不重复触发）。
    /// 返回是否受理（sheet 据此决定是否重建 WebView）。
    mutating func retry() -> Bool {
        switch phase {
        case .failed, .timedOut:
            retryCount += 1
            phase = .loading(progress: nil)
            return true
        case .idle, .loading:
            return false
        }
    }

    /// 网页进程终止自动恢复（build 38 · 反馈 2 之 ④）：
    /// 第一次终止 → 回到 loading（Coordinator 执行 reload，UI 显示加载中）；
    /// 短期内再次终止（flag 由调用方持有）→ failed 走人工重试。
    mutating func autoReload() {
        phase = .loading(progress: nil)
    }
}

/// build 38 · 反馈 2 之 ③：验证 WebView cookie → URLSession 的共享闭环。
///
/// 此前闭环只传递 be_captcha_token 一个值（Keychain），验证 WebView 里
/// WKWebsiteDataStore.default() 种下的其它会话 cookie（PHPSESSID 等）不会
/// 随 YtysxsAdapter 的 URLSession 请求发出——验证通过后搜索仍可能再次触发
/// 验证。本工具把 WKHTTPCookieStore 里悦听域下的全部 cookie 同步进
/// HTTPCookieStorage.shared（URLSession 默认读它），完成真正的 cookie 共享；
/// be_captcha_token 的 Keychain 显式注入路径保留（双保险）。
enum YtysxsCookieSync {

    /// 悦听有声主域（含子域）。不使用 hasSuffix 裸匹配，避免近形域误入。
    static let allowedDomainSuffix = ".ytysxs.com"

    /// cookie 是否属于悦听域（domain 形如 "ytysxs.com" / ".ytysxs.com" / "www.ytysxs.com"）
    static func isYtysxsCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain
        if domain == "ytysxs.com" { return true }
        return domain.hasSuffix(allowedDomainSuffix)
    }

    /// 从 WKWebView getAllCookies 回包中筛出悦听域 cookie
    static func ytysxsCookies(from cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { isYtysxsCookie($0) }
    }

    /// be_captcha_token 捕获（非空才算命中——空值 cookie 视为未通过验证）
    static func captchaToken(from cookies: [HTTPCookie]) -> String? {
        guard let token = cookies.first(where: { $0.name == "be_captcha_token" })?.value,
              !token.isEmpty else { return nil }
        return token
    }

    /// 把悦听域 cookie 写入 URLSession 侧存储（默认 HTTPCookieStorage.shared，
    /// 后续 APIClient 的 URLSession 请求自动携带）
    @discardableResult
    static func sync(_ cookies: [HTTPCookie], into storage: HTTPCookieStorage) -> Int {
        var synced = 0
        for cookie in ytysxsCookies(from: cookies) {
            storage.setCookie(cookie)
            synced += 1
        }
        return synced
    }
}
