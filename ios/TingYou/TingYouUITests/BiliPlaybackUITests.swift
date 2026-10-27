import XCTest

/// build 45 · 反馈 1c/4：B站真实播放用例（H）+ 全局收键盘多点位用例（G 扩点）。
/// 沙箱无模拟器——本文件为 CI 侧可执行规格（XCUITest 真实点击），断言判据
/// 不依赖喇叭/声音：播放态以 UI 元素/时间轴判，失败态以透传错误文案判。
final class BiliPlaybackUITests: XCTestCase {

    /// 用例 H：B站真实播放链路。搜索「新水浒传」→ B站结果行 → 详情 →
    /// 点第一集 → 断言：进入播放态，或失败但错误文案已透传（含 [诊断] 分层
    /// 原文——这正是反馈 1a 的交付物：用户/CI 截图即可定位坏在哪一层）。
    /// 判据不依赖音频输出（模拟器静音不影响）：播放态断言暂停按钮出现，
    /// 失败态断言含「[诊断]」的错误文本出现。
    func testH_biliRealPlaybackOrTransparentError() {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["discover_search_field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "用例 H 前置失败：搜索框未出现")
        field.tap()
        field.typeText("新水浒传\n")

        // 聚合结果按固定顺序（听友在前、B站在后）——取含「B站」源标的行
        let biliRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'B站' AND label CONTAINS '新水浒传'"))
            .firstMatch
        XCTAssertTrue(biliRow.waitForExistence(timeout: 20),
                      "用例 H 前置失败：搜索结果中未出现 B站《新水浒传》（检查 B站源开关/网络）")
        biliRow.tap()
        XCTAssertTrue(app.staticTexts["album_screen_title"].waitForExistence(timeout: 10),
                      "用例 H 前置失败：点击 B站结果行未进入详情页")

        // 点第一集：B站章节标题来自 pagelist part 字段（UP 自定义名，不一定
        // 以「P1」开头——CI 第二轮 5s 等不到 P1 的根因），直接用首个章节 cell。
        let firstCell = app.descendants(matching: .any)
            .matching(identifier: "album_chapter_row_0").firstMatch
        if !firstCell.exists {
            let anyCell = app.cells.firstMatch
            XCTAssertTrue(anyCell.waitForExistence(timeout: 5),
                          "用例 H 前置失败：详情页章节列表未出现")
            anyCell.tap()
        } else {
            firstCell.tap()
        }

        // 判定窗口 30s，三判据任一（build 45.2 · CI 第二轮修订）：
        // ① 全屏 PlayerScreen「暂停」（identifier player_play_pause）
        // ② mini 播放栏暂停态（identifier mini_play_pause + label「暂停」——
        //    CI 第二轮实况：点集后 App 停在详情页 + MiniPlayerBar 播放，
        //    但 mini 按钮当时只有 SF Symbol 无锚，判据看不见它）
        // ③ [诊断] 错误文案透传（取流挂起 20s 看门狗兜底，30s 内必达其一）。
        // 附兜底：15s 仍无判据时 tap mini 播放栏打开全屏 PlayerScreen 再断言。
        let diag = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS '[诊断]'")).firstMatch
        let deadline = Date().addingTimeInterval(30)
        var playing = false
        var transparentError = false
        while Date() < deadline {
            // 判据①全屏播放器暂停锚（identifier player_play_pause + label 暂停）
            if app.buttons["暂停"].exists { playing = true; break }
            // 判据②mini 播放栏暂停锚（build 45.2 新增——CI 第二轮实况：点集后
            // App 停在详情页 + MiniPlayerBar，播放其实在 mini 栏，判据看不见它）
            if app.buttons.matching(identifier: "mini_play_pause")
                .matching(NSPredicate(format: "label == '暂停'")).firstMatch.exists {
                playing = true; break
            }
            // 判据③[诊断] 透传（watchdog 20s 兜底，30s 窗口内必达其一）
            if diag.exists { transparentError = true; break }
            sleep(1)
        }
        if !playing && !transparentError {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "view_tree_bili_playback_timeout"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(playing || transparentError,
                      "用例 H 失败：30s 内既未进入播放态（全屏/mini 暂停锚），也未出现含 [诊断] 的透传错误文案（视图树快照已附加）")
    }

    /// 用例 G（build 45 扩点）：全局收键盘多点位——键盘弹起后分别点
    /// 搜索栏上方 / 分类行区 / 列表空白 / 底部 tab 区，键盘都必须收起
    /// （window 级 recognizer 兜底）；收起后行导航哨兵必须仍正常
    /// （点书进详情——任何点位吞事件即本用例红，全局方案回退信号）。
    /// build 45.2 · CI 第二轮：XCUITest 模拟器基础设施抖动
    ///（「Failed to get background assertion … Timed out」）一次重试容忍
    ///——CI 证据：同环境 C 与旧 G 通过，60.5s 的 G 失败是 infra 抖动而非
    /// 键盘断言失败。机制：override record(_:) 捕获含「background assertion」
    /// 的 issue 置标记，点位循环检测到标记时重开 app 并重试该点位一次。
    private var infraFlakeDetected = false

    override func record(_ issue: XCTIssue) {
        if issue.compactDescription.contains("background assertion") {
            infraFlakeDetected = true
        }
        super.record(issue)
    }

    func testG_multiPointTapDismissesKeyboardAndNavigationSurvives() {
        var app = XCUIApplication()
        app.launch()
        var field = app.textFields["discover_search_field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "用例 G 前置失败：搜索框未出现")
        field.tap()
        XCTAssertTrue(app.keyboards.count > 0, "用例 G 前置失败：点击搜索框键盘未弹起")

        // 多点位：搜索栏上方 / 分类行区 / 列表空白区（若命中某行则同时验证导航）
        // infra 抖动容错：background assertion 失败（tap 层 infra，非键盘断言）
        // 时重开 app、重新聚焦搜索框、该点位重试一次；仍失败才如实红。
        let points = [(0.5, 0.08), (0.5, 0.20), (0.5, 0.72)]
        for (nx, ny) in points {
            infraFlakeDetected = false
            app.coordinate(withNormalizedOffset: CGVector(dx: nx, dy: ny)).tap()
            if infraFlakeDetected {
                app.terminate()
                app = XCUIApplication()
                app.launch()
                field = app.textFields["discover_search_field"]
                XCTAssertTrue(field.waitForExistence(timeout: 10),
                              "用例 G infra 重试前置失败：重启后搜索框未出现")
                field.tap()
                infraFlakeDetected = false
                app.coordinate(withNormalizedOffset: CGVector(dx: nx, dy: ny)).tap()
            }
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"),
                                                 object: app.keyboards)
            let result = XCTWaiter.wait(for: [gone], timeout: 5)
            XCTAssertTrue(result == .completed,
                          "用例 G 失败：点 (\(nx), \(ny)) 后 5s 内键盘未收起——全局收键盘覆盖空洞（若刚发生 background assertion 重试仍红，请结合 C/旧 G 判定是否纯 infra）")
        }

        // 导航哨兵：键盘收起后点书必须仍能进详情（recognizer 不吞事件）
        if app.staticTexts["album_screen_title"].exists { app.navigationBars.buttons.firstMatch.tap() }
        field.tap()
        field.typeText("水浒\n")
        let row = app.descendants(matching: .any)
            .matching(identifier: "discover_search_row_0").firstMatch
        if !row.waitForExistence(timeout: 10) {
            let anyRow = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS '水浒'")).firstMatch
            XCTAssertTrue(anyRow.waitForExistence(timeout: 10), "用例 G 前置失败：搜索结果未出现")
            anyRow.tap()
        } else {
            row.tap()
        }
        XCTAssertTrue(app.staticTexts["album_screen_title"].waitForExistence(timeout: 10),
                      "用例 G 失败：收键盘后点书行未进详情——recognizer 吞事件（A/B 哨兵同源回归）")
    }
}
