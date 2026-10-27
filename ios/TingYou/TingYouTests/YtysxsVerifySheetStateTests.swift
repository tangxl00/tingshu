import XCTest
@testable import TingYou

/// build 38 · 反馈 2：悦听验证 sheet 加载状态机 + cookie 闭环单元测试。
///
/// 测试环境无法跑真机 WKWebView（最终需用户真机验收），但状态机与 cookie
/// 捕获/同步均为纯逻辑，本套件把迁移规则钉死：
/// - 状态机：start / updateProgress / finish / fail / timeout / retry / autoReload
///   的全部合法迁移与非法迁移（迟到超时不覆盖、loading 中重试被拒、进度夹取）；
/// - cookie：be_captcha_token 捕获（非空判定）、悦听域过滤（近形域不入）、
///   同步写入仅悦听域。
final class YtysxsVerifySheetStateTests: XCTestCase {

    // MARK: - 状态机 · 基本迁移

    func testInitialPhaseIsIdle() {
        let machine = VerifyLoadStateMachine()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.isLoading)
        XCTAssertEqual(machine.retryCount, 0)
    }

    func testStartEntersLoadingWithUnknownProgress() {
        var machine = VerifyLoadStateMachine()
        machine.start()
        XCTAssertEqual(machine.phase, .loading(progress: nil))
        XCTAssertTrue(machine.isLoading)
    }

    func testFinishReturnsToIdle() {
        var machine = VerifyLoadStateMachine()
        machine.start()
        machine.finish()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.isLoading)
    }

    // MARK: - 状态机 · 进度

    func testUpdateProgressOnlyAcceptedWhileLoading() {
        var machine = VerifyLoadStateMachine()
        // idle 态的迟到进度回包不生效
        machine.updateProgress(0.5)
        XCTAssertEqual(machine.phase, .idle)
        // loading 态正常回包
        machine.start()
        machine.updateProgress(0.42)
        XCTAssertEqual(machine.phase, .loading(progress: 0.42))
        // finish 后的迟到进度回包不复活加载态
        machine.finish()
        machine.updateProgress(0.9)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testUpdateProgressClampsOutOfRangeValues() {
        var machine = VerifyLoadStateMachine()
        machine.start()
        machine.updateProgress(-0.5)
        XCTAssertEqual(machine.phase, .loading(progress: 0))
        machine.updateProgress(1.7)
        XCTAssertEqual(machine.phase, .loading(progress: 1))
    }

    // MARK: - 状态机 · 失败 / 超时

    func testFailSetsReason() {
        var machine = VerifyLoadStateMachine()
        machine.start()
        machine.fail("连接被拒绝")
        XCTAssertEqual(machine.phase, .failed(reason: "连接被拒绝"))
        XCTAssertFalse(machine.isLoading)
    }

    func testTimeoutOnlyFiresWhileLoading() {
        var machine = VerifyLoadStateMachine()
        // idle 态超时不生效
        machine.timeout()
        XCTAssertEqual(machine.phase, .idle)
        // loading 态超时生效
        machine.start()
        machine.timeout()
        XCTAssertEqual(machine.phase, .timedOut)
        // 迟到超时不覆盖已回包结果（didFinish 已 finish）
        machine.start()
        machine.finish()
        machine.timeout()
        XCTAssertEqual(machine.phase, .idle)
        // 迟到超时不覆盖失败态
        machine.start()
        machine.fail("DNS 解析失败")
        machine.timeout()
        XCTAssertEqual(machine.phase, .failed(reason: "DNS 解析失败"))
    }

    // MARK: - 状态机 · 重试

    func testRetryAcceptedFromFailedAndTimedOut() {
        var machine = VerifyLoadStateMachine()
        machine.start()
        machine.fail("超时")
        XCTAssertTrue(machine.retry())
        XCTAssertEqual(machine.phase, .loading(progress: nil))
        XCTAssertEqual(machine.retryCount, 1)

        machine.timeout()
        XCTAssertTrue(machine.retry())
        XCTAssertEqual(machine.phase, .loading(progress: nil))
        XCTAssertEqual(machine.retryCount, 2)
    }

    func testRetryRejectedWhileLoadingOrIdle() {
        var machine = VerifyLoadStateMachine()
        // loading 中不重复触发（防止重试按钮连点重建 WebView）
        machine.start()
        XCTAssertFalse(machine.retry())
        XCTAssertEqual(machine.retryCount, 0)
        // idle 态（导航已完成）重试无意义，拒绝
        machine.finish()
        XCTAssertFalse(machine.retry())
        XCTAssertEqual(machine.retryCount, 0)
    }

    // MARK: - 状态机 · 进程终止自动恢复

    func testAutoReloadReturnsToLoading() {
        var machine = VerifyLoadStateMachine()
        machine.start()
        machine.finish()
        // 进程终止自动恢复：回到 loading（是否自动 reload 由 Coordinator 的
        // 一次性 flag 控制，状态机只负责呈现加载态）
        machine.autoReload()
        XCTAssertEqual(machine.phase, .loading(progress: nil))
        XCTAssertTrue(machine.isLoading)
    }

    // MARK: - cookie · be_captcha_token 捕获

    private func cookie(name: String, value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
        ])!
    }

    func testCaptchaTokenCapturedFromCookieList() {
        let cookies = [
            cookie(name: "PHPSESSID", value: "sess123", domain: ".ytysxs.com"),
            cookie(name: "be_captcha_token", value: "tok456", domain: ".ytysxs.com"),
        ]
        XCTAssertEqual(YtysxsCookieSync.captchaToken(from: cookies), "tok456")
    }

    func testCaptchaTokenNilWhenMissingOrEmpty() {
        // 无 token cookie
        XCTAssertNil(YtysxsCookieSync.captchaToken(from: [
            cookie(name: "PHPSESSID", value: "s", domain: ".ytysxs.com"),
        ]))
        // 空值 token 视为未通过验证
        XCTAssertNil(YtysxsCookieSync.captchaToken(from: [
            cookie(name: "be_captcha_token", value: "", domain: ".ytysxs.com"),
        ]))
        // 空列表
        XCTAssertNil(YtysxsCookieSync.captchaToken(from: []))
    }

    // MARK: - cookie · 悦听域过滤

    func testYtysxsDomainFilterAcceptsApexAndSubdomains() {
        let cookies = [
            cookie(name: "a", value: "1", domain: "ytysxs.com"),      // 顶点域
            cookie(name: "b", value: "2", domain: ".ytysxs.com"),     // 带点前缀
            cookie(name: "c", value: "3", domain: "www.ytysxs.com"),  // 子域
        ]
        XCTAssertEqual(YtysxsCookieSync.ytysxsCookies(from: cookies).count, 3)
        XCTAssertTrue(cookies.allSatisfy { YtysxsCookieSync.isYtysxsCookie($0) })
    }

    func testYtysxsDomainFilterRejectsForeignAndLookalikeDomains() {
        let foreign = [
            cookie(name: "x", value: "1", domain: "tingyou.fm"),
            cookie(name: "y", value: "2", domain: "bilibili.com"),
            // 近形域：后缀字符串相似但不是 ytysxs.com 的子域
            cookie(name: "z", value: "3", domain: "evilytysxs.com"),
            cookie(name: "w", value: "4", domain: "ytysxs.com.evil.cn"),
        ]
        XCTAssertTrue(foreign.allSatisfy { !YtysxsCookieSync.isYtysxsCookie($0) })
        XCTAssertTrue(YtysxsCookieSync.ytysxsCookies(from: foreign).isEmpty)
    }

    // MARK: - cookie · 同步写入

    func testSyncWritesOnlyYtysxsCookiesIntoStorage() {
        // build 38 · 反馈 2 ③：验证 WebView 会话 cookie 同步进 URLSession 侧
        // 存储——用共享存储实测写入，并断言只写入悦听域（写后清理，避免污染）。
        let storage = HTTPCookieStorage.shared
        let ytysxs = cookie(name: "sync_test_sess", value: "abc", domain: ".ytysxs.com")
        let foreign = cookie(name: "sync_test_foreign", value: "xyz", domain: "bilibili.com")

        let written = YtysxsCookieSync.sync([ytysxs, foreign], into: storage)
        XCTAssertEqual(written, 1, "只有悦听域 cookie 被同步")

        let stored = storage.cookies?.first { $0.name == "sync_test_sess" }
        XCTAssertNotNil(stored, "悦听域 cookie 应写入 HTTPCookieStorage")
        XCTAssertEqual(stored?.value, "abc")
        XCTAssertNil(storage.cookies?.first { $0.name == "sync_test_foreign" },
                     "非悦听域 cookie 不得写入")

        // 清理测试残留
        if let stored = stored { storage.deleteCookie(stored) }
    }
}
