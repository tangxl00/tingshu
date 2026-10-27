import XCTest

/// build 42 · 任务一（XCUITest 真实点击复现「点书不导航」）：
/// 用户真机四条全败，其中「冷启动不点搜索框直接点推荐书也进不了详情页」
/// 是决定性证据——该场景键盘从未弹起、无焦点状态、无重渲染竞争，
/// FocusState 理论被证伪。静态分析已穷尽（NavigationStack/List/行结构、
/// AlbumRow/CoverImage、ContentView/MiniPlayerBar 均干净），本轮改用
/// CI 模拟器真实点击拿运行时证据；XCUITest 失败自动截图与失败附件，
/// 即为下一步修复的定位依据。
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
    /// 直接点推荐书行，断言推入 AlbumScreen。若本用例失败，
    /// 「点书不导航」在无任何键盘/焦点变量参与的情况下即复现。
    func testA_coldStartTapRecommendRowNavigates() {
        let app = XCUIApplication()
        let row = launchAndDiscoverRow(app)
        row.tap()
        XCTAssertTrue(albumTitleElement(app).waitForExistence(timeout: 3),
                      "用例 A 失败：冷启动直接点推荐书未推入 AlbumScreen——「点书不导航」在 CI 模拟器复现（失败截图即运行时证据）")
    }

    /// 用例 B（键盘场景）：点搜索框弹键盘 → 输入（不提交——searchMode 仍为
    /// false，书库列表仍在屏）→ 点书行 → 断言导航 + 键盘收起。
    /// 与用户「键盘弹起时点书」完全同构；若 A 过而 B 败，键盘/焦点变量参与。
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

    /// 用例 C（空白收焦）：点搜索框弹键盘 → 点内容区空白带（搜索栏下方的
    /// 分类折叠行区域，非 List 行）→ 断言键盘收起。
    /// 解读线索：外层 Group 的 simultaneousGesture 逐子视图应用——若本用例
    /// 失败而 B 通过，说明手势覆盖存在空洞（子视图间隙不属任何手势区），
    /// 对应用户「点空白不收键盘」；届时修法指向背景层挂手势
    ///（Color.clear.contentShape(Rectangle()).simultaneousGesture），先拿证据再改。
    func testC_blankAreaTapDismissesKeyboard() {
        let app = XCUIApplication()
        _ = launchAndDiscoverRow(app)
        // 前置：分类折叠行应已出现（确认点击坐标落点在内容区而非导航栏/搜索栏）
        let categoryLabel = app.staticTexts["分类：推荐"]
        XCTAssertTrue(categoryLabel.waitForExistence(timeout: 3),
                      "分类行未出现——发现页结构与预期不符")
        let field = searchField(app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                      "点击搜索框后键盘未弹起——用例前置失败")
        // 点分类行区域（内容区空白带；dx 0.25 避开右侧音源 Menu，防误开菜单）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.22)).tap()
        XCTAssertTrue(keyboardGone(app, within: 2),
                      "用例 C 失败：点内容区空白带键盘不收——外层手势覆盖存在空洞（Group 逐子视图应用的已知线索）")
    }
}
