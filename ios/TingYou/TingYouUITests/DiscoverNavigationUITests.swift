import XCTest

/// build 42 · 任务一 + build 43 · 判据升级：XCUITest 真实点击六用例。
///
/// build 42 CI（run 40454528757，iOS 26.2 模拟器）证据链已闭合：
/// A/B/D 失败（单击/键盘弹起点行均不导航）· C 失败（容器手势覆盖空洞）·
/// F 语义反转（title.exists || navBars.count>0 平凡真——双击也不导航）·
/// E 对照真实通过（「我的→音源管理」push 正常，全局 NavigationLink 健康）。
/// 结论：任何容器级 tap 手势挂在包住 List 的祖先上都会杀死行 NavigationLink
/// 激活——build 43 已删除容器手势，收焦拆三路（滚动/空白小视图/导航自带）。
///
/// build 43 最终判据：A/B/C 转绿（真实点击导航恢复 + 空白收键），
/// E/F/D 保持绿（F 断言已修正为严格形态，无平凡真）。
/// 口径注意：CI 模拟器 iOS 26.2 + deployment target 17；用户真机 iOS 版本
/// 未知——若 CI 全过而用户真机失败，结论为版本相关行为（届时向用户要设备版本）。
final class DiscoverNavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 启动并等发现页推荐列表出现（ContentView 默认 selectedTab=1 发现；
    /// 列表来自 tingyou.fm 榜单，需 CI 模拟器可出网）
    private func launchAndDiscoverRow(_ app: XCUIApplication) -> XCUIElement {
        app.launch()
        let row = app.descendants(matching: .any)
            .matching(identifier: "discover_album_row_0").firstMatch
        let ok = row.waitForExistence(timeout: 25)
        XCTAssertTrue(ok, "发现页推荐列表 25 秒内未出现（模拟器网络不可用或榜单加载失败）——点击复现无法执行，先排查 CI 出网")
        return row
    }

    /// AlbumScreen 特征元素（专辑标题，DiscoverScreen 行推入后的判据）
    private func albumTitleElement(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "album_screen_title").firstMatch
    }

    /// 发现页搜索框（本页唯一 TextField，已挂 discover_search_field 标识）
    private func searchField(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "discover_search_field").firstMatch
    }

    /// 轮询等键盘消失（dismiss 是异步的，最多等 seconds 秒）
    private func keyboardGone(_ app: XCUIApplication, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while app.keyboards.firstMatch.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return !app.keyboards.firstMatch.exists
    }

    /// 用例 A（冷启动复现·决定性场景）：键盘从未弹起、无焦点状态——
    /// 直接点推荐书行，断言推入 AlbumScreen。build 42 CI 失败（59.2s），
    /// build 43 删除容器手势后应转绿——本用例是本轮修复的最终判据之一。
    func testA_coldStartTapRecommendRowNavigates() {
        let app = XCUIApplication()
        let row = launchAndDiscoverRow(app)
        row.tap()
        XCTAssertTrue(albumTitleElement(app).waitForExistence(timeout: 3),
                      "用例 A 失败：冷启动直接点推荐书未推入 AlbumScreen（失败截图即运行时证据）")
    }

    /// 用例 B（键盘场景）：点搜索框弹键盘 → 输入（不提交——searchMode 仍为
    /// false，书库列表仍在屏）→ 点书行 → 断言导航 + 键盘收起。
    /// build 42 CI 失败（51.6s），build 43 后应转绿。
    func testB_keyboardUpTapRowNavigatesAndDismisses() {
        let app = XCUIApplication()
        let row = launchAndDiscoverRow(app)
        let field = searchField(app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                      "点击搜索框后键盘未弹起——用例前置失败")
        field.typeText("abc")
        row.tap()
        XCTAssertTrue(albumTitleElement(app).waitForExistence(timeout: 3),
                      "用例 B 失败：键盘弹起时点书未推入 AlbumScreen——与用户真机现象一致（失败截图即运行时证据）")
        XCTAssertTrue(keyboardGone(app, within: 2), "导航发生后键盘未收起")
    }

    /// 用例 C（空白收焦）：点搜索框弹键盘 → 点分类标签栏里的分类标签
    /// （List 行之外的非交互区域）→ 断言键盘收起。
    /// build 48 · 需求 2：原「分类：推荐」折叠面板标题行已删，分类改为常驻
    /// 横向标签栏——点击目标同步改为标签栏内的分类标签（默认源首项「推荐」）。
    /// build 45 起收焦统一走 window 级 recognizer（全局兜底），本用例仍是
    /// 「非 List 区域点击应收键盘」的真机对齐判据。
    func testC_blankAreaTapDismissesKeyboard() {
        let app = XCUIApplication()
        _ = launchAndDiscoverRow(app)
        // 前置：常驻分类标签栏应已出现（本轮点击目标即其中一项）
        let categoryTag = app.buttons["推荐"]
        XCTAssertTrue(categoryTag.waitForExistence(timeout: 3),
                      "分类标签未出现——发现页结构与预期不符")
        let field = searchField(app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                      "点击搜索框后键盘未弹起——用例前置失败")
        // 点分类标签（非 List 行、非键盘区域）：全局收焦应触发
        categoryTag.tap()
        XCTAssertTrue(keyboardGone(app, within: 2),
                      "用例 C 失败：点分类标签键盘不收——收焦未生效")
    }

    /// 用例 D（视图树 triage）：单击行后等 5 秒，断言 AlbumScreen 出现；
    /// 失败时附加 app.debugDescription 视图树快照 + 失败截图（运行时证据）。
    /// build 42 CI 失败（单击后 5 秒 title 仍不存在）；build 43 后应转绿。
    func testD_singleTapThenViewTreeTriage() {
        let app = XCUIApplication()
        let row = launchAndDiscoverRow(app)
        row.tap()
        let title = albumTitleElement(app)
        let ok = title.waitForExistence(timeout: 5)
        if !ok {
            // triage 证据：视图树快照随失败报告携带（截图由 XCUITest 自动附加）
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "view_tree_after_single_tap"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(ok,
                      "用例 D 失败：单击行后 5 秒 AlbumScreen 未出现（视图树快照已附加，见失败附件）")
    }

    /// 用例 E（对照·全局导航健康）：「我的」tab → 音源管理 push →
    /// 断言源列表出现（「B站」；build 45 · 反馈 3 悦听下架后源行已摘除，
    /// 断言目标改 B站）。该页面链路无容器手势——build 42 CI 真实通过，
    /// 证明全局 NavigationLink 健康、问题为发现页特有。
    func testE_mineTabSourceManageNavigationWorks() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["我的"].tap()
        let entry = app.staticTexts["音源管理"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5),
                      "「我的」页音源管理入口未出现——用例前置失败")
        entry.tap()
        XCTAssertTrue(app.staticTexts["B站"].waitForExistence(timeout: 5),
                      "用例 E 失败：「我的→音源管理」push 异常——全局 NavigationLink 出现回归（对照失败，非发现页特有问题）")
    }

    /// 用例 F（双击实验·严格断言）：同一行最多点两次，断言 AlbumScreen
    /// 出现。build 42 版断言 `title.exists || navBars.count > 0` 语义反转
    /// （navBars 平凡真——发现页自身 NavigationStack 带 navigationTitle
    /// 「发现」恒 ≥1），build 43 修正为仅判 album_screen_title。
    /// 首击若已导航（title 1 秒内出现）则跳过第二击——push 后原行不可点。
    func testF_doubleTapRowNavigates() {
        let app = XCUIApplication()
        let row = launchAndDiscoverRow(app)
        row.tap()
        if !albumTitleElement(app).waitForExistence(timeout: 1) {
            row.tap()
        }
        XCTAssertTrue(albumTitleElement(app).waitForExistence(timeout: 3),
                      "用例 F 失败：双击行后 AlbumScreen 未出现——严格断言（无平凡真），首击与次击均未激活导航")
    }

    /// 用例 G（build 44 · 反馈 1 空白收焦补覆盖）：点搜索框弹键盘 →
    /// 点「搜索栏上方空白」（搜索栏外层 .padding(.vertical, 8) 区，即
    /// 「发现」标题与搜索框之间的留白）→ 断言键盘收起。
    /// build 43 只挂了三处（间距区/分类行/错误占位区），用户真机点
    /// 「页面上方空白」仍不收——build 44 把搜索栏容器整行（含 padding
    /// 留白）纳入 contentShape + simultaneousGesture，本用例是该扩围的
    /// 真机对齐判据。坐标取搜索框上沿上方 10pt（外层 8pt padding 命中区），
    /// 顶部安全区兜底。
    func testG_tapAboveSearchBarDismissesKeyboard() {
        let app = XCUIApplication()
        _ = launchAndDiscoverRow(app)
        let field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 3),
                      "搜索框未出现——发现页结构与预期不符")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                      "点击搜索框后键盘未弹起——用例前置失败")
        // 搜索栏上方空白坐标：field 上沿 -10pt（落在搜索栏容器外层 padding 区），
        // 横向取 field 中线；顶部兜底不越过安全区上沿
        let f = field.frame
        let dy = max(f.minY - 10, f.minY > 0 ? 2 : 0)
        let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: f.midX, dy: dy))
        coord.tap()
        XCTAssertTrue(keyboardGone(app, within: 2),
                      "用例 G 失败：点搜索栏上方空白键盘不收——搜索栏容器收焦挂点未覆盖 padding 留白区")
    }

    /// 用例 H（build 48 · 需求 1 回归守卫）：点搜索框弹键盘（历史区因聚焦
    /// 出现，书库列表整体下移）→ 不输入任何文字 → 直接点书行 → 断言推入
    /// AlbumScreen。
    /// 这条路径是 build 48「历史区点击才显示」引入的新风险面：点行失焦 →
    /// 历史区消失 → 列表回位（布局位移）与行激活同时发生。b41 的真机回归
    /// （点书无反应）根因正是「焦点翻转引发全 body 重渲染、丢弃进行中的行
    /// 激活」——b48 把焦点读写隔离进叶子视图后，本用例是这条路径的真实
    /// 点击判据（聚焦态下点书必须照常导航）。
    func testH_focusSearchThenTapRowNavigates() {
        let app = XCUIApplication()
        let row = launchAndDiscoverRow(app)
        let field = searchField(app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                      "点击搜索框后键盘未弹起——用例前置失败")
        // 历史区出现会把书库列表整体下移——不可点时上滑一次保证命中
        if !row.isHittable {
            app.swipeUp()
        }
        row.tap()
        XCTAssertTrue(albumTitleElement(app).waitForExistence(timeout: 3),
                      "用例 H 失败：聚焦态下点书未推入 AlbumScreen（build 48 需求 1：失焦隐藏历史区的布局位移不得打断行导航激活）")
    }
}
