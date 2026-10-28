import XCTest
@testable import TingYou

/// build 32（v1.4.3）回归：P0 播放修复（B站 CDN 代理分流 / 播放失败文案）+
/// 需求 1/2（书架导入入口删除、搜索历史聚焦态）源码结构断言。流式代理与
/// AVPlayer 集成为运行时行为，沙箱无 xcodebuild 由 CI 兜底；此处锁定可静态
/// 验证的纯函数面与关键接线。
final class Build32RegressionTests: XCTestCase {

    // MARK: - P0 · ProxiedCdnHosts 代理域判定（取证 A：B站 CDN 裸请求一律 403）

    func testNeedsProxyAcceptsBiliCdnDomains() {
        XCTAssertTrue(ProxiedCdnHosts.needsProxy("bilivideo.com"))
        XCTAssertTrue(ProxiedCdnHosts.needsProxy("cn-sh-cc-01-03.bilivideo.com"),
                      "实测 playurl 下发的 DASH 域名必须命中代理")
        XCTAssertTrue(ProxiedCdnHosts.needsProxy("akamaized.net"))
        XCTAssertTrue(ProxiedCdnHosts.needsProxy("upos-hz-mirrorakam.akamaized.net"))
        XCTAssertTrue(ProxiedCdnHosts.needsProxy("hdslb.com"))
        XCTAssertTrue(ProxiedCdnHosts.needsProxy("i0.hdslb.com"))
    }

    func testNeedsProxyRejectsApiAndOtherSourceDomains() {
        // B站 API 域：请求自带 Referer/UA（BiliAdapter 独立 session），无需代理
        XCTAssertFalse(ProxiedCdnHosts.needsProxy("www.bilibili.com"))
        XCTAssertFalse(ProxiedCdnHosts.needsProxy("api.bilibili.com"))
        XCTAssertFalse(ProxiedCdnHosts.needsProxy("b23.tv"))
        // 其余音源直链域：此前 redirect 语义线上验证可行，不进代理路径
        XCTAssertFalse(ProxiedCdnHosts.needsProxy("audio.xmcdn.com"))
        XCTAssertFalse(ProxiedCdnHosts.needsProxy("fdfs.xmcdn.com"))
        XCTAssertFalse(ProxiedCdnHosts.needsProxy("tingyou.cn"))
        XCTAssertFalse(ProxiedCdnHosts.needsProxy(""))
    }

    func testNeedsProxyRejectsLookalikeDomains() {
        XCTAssertFalse(ProxiedCdnHosts.needsProxy("evilbilivideo.com"))
        XCTAssertFalse(ProxiedCdnHosts.needsProxy("bilivideo.com.evil.com"))
        XCTAssertFalse(ProxiedCdnHosts.needsProxy("notbilivideo.com"))
    }

    // MARK: - P0 · describePlaybackError（取证 D：静默失败修复的人话文案）

    func testTing59NonNetworkFailureReportsSiteSideOutage() {
        // 取证 B 实测：xmcdn 直链已被 CDN 全面拒绝（403/404），非 App 可修——
        // 非客户端网络类错误一律按站点侧源失效提示，引导换源
        let msg = PlaybackManager.describePlaybackError(
            URLError(.badServerResponse), source: "ting59")
        XCTAssertTrue(msg.contains("59听书网音频源当前不可用"), "ting59 失效应给出站点侧失效文案：\(msg)")
        XCTAssertTrue(msg.contains("换用其他音源"), "应引导换源：\(msg)")
    }

    func testTing59NetworkFailureReportsNetworkIssue() {
        let offline = PlaybackManager.describePlaybackError(
            URLError(.notConnectedToInternet), source: "ting59")
        XCTAssertTrue(offline.contains("网络"), "客户端断网不能误报站点失效：\(offline)")
        let timeout = PlaybackManager.describePlaybackError(
            URLError(.timedOut), source: "ting59")
        XCTAssertTrue(timeout.contains("网络"), "超时属客户端网络问题：\(timeout)")
    }

    func testGenericSourceErrorMappings() {
        let offline = PlaybackManager.describePlaybackError(
            URLError(.notConnectedToInternet), source: SourceRegistry.TINGYOU)
        XCTAssertTrue(offline.contains("网络"))
        let timedOut = PlaybackManager.describePlaybackError(
            URLError(.timedOut), source: SourceRegistry.BILI)
        XCTAssertTrue(timedOut.contains("超时"))
        let badServer = PlaybackManager.describePlaybackError(
            URLError(.badServerResponse), source: SourceRegistry.BILI)
        XCTAssertTrue(badServer.contains("响应异常"))
    }

    // MARK: - 需求 1 · 搜索历史显隐（build 48：聚焦驱动 + 全量换行）

    /// build 48 · 需求 1：历史搜索区显隐语义从「keyword 驱动」改回
    /// 「聚焦驱动」——只有搜索框聚焦且未输入关键词时才挂载历史区。
    /// b41 删 @FocusState 的根因是「焦点状态翻转触发全 body 重渲染，丢弃
    /// 进行中的 NavigationLink 行激活」——b48 用叶子视图隔离焦点读写
    /// （主视图 body 只写不读焦点态），回归风险由 DiscoverNavigationUITests
    /// A/B/H 真实点击守卫承担。
    /// 同时钉住「全量换行显示」：≤8 条 / 160pt 限高 / 内嵌 ScrollView
    /// 三个截断形态必须全部消失，chip 流式换行布局保留。
    func testDiscoverHistoryVisibilityFocusDriven() throws {
        let source = try loadSource("DiscoverScreen")
        let code = Self.codeOnly(source)
        // 焦点态：1 处状态声明 + 2 处 FocusState.Binding 下发（叶子隔离）
        XCTAssertTrue(code.contains("@FocusState private var searchFieldFocused: Bool"),
                      "发现页必须保留聚焦态（build 48 需求 1：聚焦才显示历史区）")
        XCTAssertEqual(code.components(separatedBy: "@FocusState").count - 1, 3,
                       "焦点态形态必须固定：1 处状态声明 + 2 处 FocusState.Binding 下发（build 48 焦点隔离）")
        XCTAssertTrue(code.contains("@FocusState.Binding var focused: Bool"),
                      "聚焦态必须以 FocusState.Binding 下发给叶子视图（build 41 回归防线）")
        // 显隐条件只在叶子门卫内判定
        XCTAssertTrue(code.contains("if focused && keywordIsEmpty {"),
                      "历史区显隐条件必须在叶子门卫内判定（聚焦 && 关键词为空）")
        XCTAssertFalse(code.contains("if searchFieldFocused"),
                       "主视图不得直接以 searchFieldFocused 参与条件判断（焦点读隔离）")
        // 全量换行显示：截断形态全部消失
        XCTAssertFalse(code.contains("history.count <= 8"),
                       "不得再按条数分流（build 48 需求 1：历史条目全量显示）")
        XCTAssertFalse(code.contains("frame(height: 160)"),
                       "不得再固定 160pt 限高（build 48 需求 1：全量换行显示）")
        XCTAssertFalse(code.contains("ScrollView { historyList }"),
                       "不得再包内嵌 ScrollView（build 48 需求 1：全量换行显示）")
        XCTAssertFalse(code.contains("maxHeight:"),
                       "maxHeight 贪婪形态不得回归（少历史时撑出空白）")
        // chip 流式换行布局保留
        XCTAssertTrue(code.contains("LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 6)"),
                      "历史词条必须保留 LazyVGrid 自适应换行布局（多行流式排布）")
        // 无条件的常驻挂载形态应已消失（旧形态为「historySection\n                    libraryContent」紧邻）
        XCTAssertFalse(source.contains("                    historySection\n                    libraryContent"),
                       "historySection 不应无条件常驻挂载")
    }

    // MARK: - 需求 1 · 书架导入入口删除（源码结构断言）

    func testShelfImportEntryRemoved() throws {
        let source = try loadSource("ShelfScreen")
        // build 48 · 需求 3：书架「导入」tab 及其空态页整体删除——断言口径
        // 从「导入页内容卡片应保留」翻转为「导入页内容卡片必须消失」。
        // 用剔除整行注释的源码（删除说明注释里含标识符名，不参与判定）。
        let code = Self.codeOnly(source)
        XCTAssertFalse(source.contains("showBiliImport"),
                       "B站导入入口 @State 应已删除")
        XCTAssertFalse(source.contains("showTing59Import"),
                       "59听书导入入口 @State 应已删除")
        XCTAssertFalse(source.contains("Label(\"B站导入\""),
                       "「+」Menu 的 B站导入项应已删除")
        // build 48 · 需求 3：导入 tab + 导入内容卡片 + 空态页一并移除
        XCTAssertFalse(code.contains("importedContent"),
                       "导入 tab 的内容卡片视图必须已删除（build 48 需求 3：书架只保留收藏/历史两 tab）")
        XCTAssertFalse(code.contains("暂无导入书籍"),
                       "导入空态页文案必须已删除（build 48 需求 3）")
        XCTAssertFalse(code.contains("ImportedBookRow"),
                       "导入行视图必须已删除（build 48 需求 3）")
        XCTAssertFalse(code.contains("ImportedBookGridItem"),
                       "导入网格项视图必须已删除（build 48 需求 3）")
        XCTAssertFalse(code.contains("selectedTab == 2"),
                       "不得残留第三 tab 分支（导入 tab 已删）")
        // 边界：收藏 / 历史两 tab 必须保留
        XCTAssertTrue(code.contains("favoritesContent"), "收藏 tab 内容必须保留")
        XCTAssertTrue(code.contains("historyContent"), "历史 tab 内容必须保留")
    }

    // MARK: - 辅助

    /// 剔除整行注释（trim 后以 // 开头）——删除说明注释里含被断言的标识符名，
    /// 参与判定前必须剔除，避免注释命中/误伤。
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func loadSource(_ fileName: String) throws -> String {
        // #filePath = …/TingYouTests/Build32RegressionTests.swift
        // 上溯两级到 TingYou 工程目录，源码在 TingYou/UI/**/ 下（与 CI checkout 布局一致）
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let candidates = [
            projectDir + "/TingYou/UI/Discover/DiscoverScreen.swift",
            projectDir + "/TingYou/UI/Shelf/ShelfScreen.swift",
        ]
        guard let path = candidates.first(where: { $0.contains(fileName) }),
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("源码布局变化：找不到 \(fileName) 源文件")
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }
}
