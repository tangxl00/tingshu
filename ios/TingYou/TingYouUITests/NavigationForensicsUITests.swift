import XCTest

/// build 42 · 组长追加取证轮（不改生产代码）：
/// 用例 A/B/C 已在 CI 复现「点书不导航」，但现有断言只判目标元素存在，
/// 无法区分「未导航」与「导航了但 AlbumScreen 渲染异常」。
/// 本文件三条取证用例把证据塞进断言消息（断言消息会完整进入 test.log，
/// print 不会——已被 build 37 诊断轮实证）。
final class NavigationForensicsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launchAndDiscoverRow(_ app: XCUIApplication) -> XCUIElement {
        app.launch()
        let row = app.descendants(matching: .any)
            .matching(identifier: "discover_album_row_0").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 25),
                      "发现页推荐列表 25 秒内未出现——CI 出网或榜单加载失败")
        return row
    }

    /// 用例 D（视图树取证）：点推荐行后 dump 导航栏计数 + 树中关键行。
    /// 无论导航是否发生，失败消息里都会带出运行时层级证据：
    /// - navBarCount > 0 且出现 Album 相关 → 实际导航了、是判据/渲染问题；
    /// - navBarCount == 0 → 未导航，问题在发现页 NavigationStack/行激活层。
    func testZ_dumpHierarchyAfterTap() {
        let app = XCUIApplication()
        let row = launchAndDiscoverRow(app)
        row.tap()
        // 给 push 动画与页面渲染留时间
        // RunLoop 等待替代 sleep（等待 push 动画与渲染）
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let navBars = app.navigationBars
        let tree = app.debugDescription
        let keyLines = tree.split(separator: "\n")
            .filter { $0.contains("NavigationBar") || $0.contains("Album")
                     || $0.contains("专辑") || $0.contains("返回")
                     || $0.contains("Back") || $0.contains("Button") && $0.contains("discover") }
            .map(String.init)
        let summary = """
        D-取证 | navBarCount=\(navBars.count) \
        | navBarIds=\(navBars.allElementsBoundByIndex.map(\.identifier)) \
        | treeKeyLines=\(keyLines.joined(separator: " ⏎ ").prefix(1500)) \
        | treeTotalLines=\(tree.split(separator: "\n").count)
        """
        let title = app.descendants(matching: .any)
            .matching(identifier: "album_screen_title").firstMatch
        _ = title.waitForExistence(timeout: 2)
        XCTAssertTrue(title.exists || navBars.count > 0, summary)
    }

    /// 用例 E（我的页导航对照）：MineScreen 的 NavigationLink（「音源管理」）
    /// 是否正常导航——区分「发现页特有问题」与「全 App NavigationLink 失效」。
    /// 若 E 过而 A 败 → 发现页特有；若 E 也败 → 全局性问题。
    func testZ_mineTabNavigationControl() {
        let app = XCUIApplication()
        app.launch()
        let mineTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(mineTab.waitForExistence(timeout: 10), "「我的」tab 未出现")
        mineTab.tap()
        let link = app.staticTexts["音源管理"]
        XCTAssertTrue(link.waitForExistence(timeout: 5),
                      "「音源管理」入口未出现——MineScreen 结构与预期不符")
        link.tap()
        // 音源管理页特征：含音源名称列表（悦听有声书 等）或新导航栏
        let arrived = app.staticTexts["悦听有声书"].waitForExistence(timeout: 4)
            || app.staticTexts["本地听"].waitForExistence(timeout: 4)
        let navAfter = app.navigationBars.allElementsBoundByIndex.map(\.identifier)
        XCTAssertTrue(arrived, "E-对照失败：我的页 NavigationLink 也未导航——全局性问题 | navBarIds=\(navAfter)")
    }

    /// 用例 F（双击实验）：同一行连续 tap 两次。
    /// 若「首击被某机制消费、次击才导航」成立，第二次 tap 后应出现 Album 页
    /// ——失败消息带出 navBar 证据；两次都失败则彻底排除该理论。
    func testZ_doubleTapExperiment() {
        let app = XCUIApplication()
        let row = launchAndDiscoverRow(app)
        row.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        row.tap()
        // RunLoop 等待替代 sleep（等待 push 动画与渲染）
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let navBars = app.navigationBars
        let title = app.descendants(matching: .any)
            .matching(identifier: "album_screen_title").firstMatch
        let summary = "F-取证 | navBarCount=\(navBars.count) | navBarIds=\(navBars.allElementsBoundByIndex.map(\.identifier))"
        XCTAssertTrue(title.exists || navBars.count > 0, summary)
    }
}
