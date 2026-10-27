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

    // MARK: - 需求 2 · 搜索历史聚焦态（源码结构断言：仅聚焦时挂载 historySection）

    func testDiscoverHistoryMountsOnlyWhenFocused() throws {
        let source = try loadSource("DiscoverScreen")
        // 需求 2：@FocusState 接线存在
        XCTAssertTrue(source.contains("@FocusState private var searchFocused: Bool"),
                      "搜索框须有聚焦态标记")
        XCTAssertTrue(source.contains(".focused($searchFocused)"),
                      "TextField 须绑定聚焦态")
        // historySection 的挂载被 searchFocused 条件包住（不再常驻）
        XCTAssertTrue(source.contains("if searchFocused {"),
                      "historySection 应仅在聚焦分支内挂载")
        // 无条件的常驻挂载形态应已消失（旧形态为「historySection\n                    libraryContent」紧邻）
        XCTAssertFalse(source.contains("                    historySection\n                    libraryContent"),
                       "historySection 不应再无条件常驻挂载")
    }

    // MARK: - 需求 1 · 书架导入入口删除（源码结构断言）

    func testShelfImportEntryRemoved() throws {
        let source = try loadSource("ShelfScreen")
        XCTAssertFalse(source.contains("showBiliImport"),
                       "B站导入入口 @State 应已删除")
        XCTAssertFalse(source.contains("showTing59Import"),
                       "59听书导入入口 @State 应已删除")
        XCTAssertFalse(source.contains("Label(\"B站导入\""),
                       "「+」Menu 的 B站导入项应已删除")
        // 边界：导入页保留（已导入书籍仍显示与播放），导入内容卡片还在
        XCTAssertTrue(source.contains("importedContent"), "导入页内容卡片应保留")
    }

    // MARK: - 辅助

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
