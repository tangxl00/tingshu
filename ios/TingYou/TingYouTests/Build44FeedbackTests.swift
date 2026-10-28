import XCTest
@testable import TingYou

/// build 44 · 五项反馈修复的回归测试。
///
/// 覆盖口径：
/// 1. B站分P纯函数（buildPageListUrl / parsePageList）——Cannot Open 修复的
///    解析层单测（网络层取证见交付说明：view 连续 3 次 412、pagelist 3 次 200）；
/// 2. 悦听相关用例已随 build 45 · 反馈 3（悦听全链摘除）整体移除；
/// 3. 听友FM TLS 错误人话映射形态守卫；
/// 4. 历史搜索滚动展示（不再单条截断 / 只见部分）形态守卫。
/// 源码形态守卫沿用 Build29RegressionTests 的「剔除整行注释 + whitespace
/// 归一化」口径（沙箱无 Swift 工具链，静态断言为唯一可执行口径；CI 上跑
/// xcodebuild 全量单测兜底）。
final class Build44FeedbackTests: XCTestCase {

    // MARK: - 反馈 3 · B站分P纯函数

    /// pagelist URL 构造：轻接口零风控（对照 view 的 412），格式必须稳定
    func testBuildPageListUrlFormat() {
        XCTAssertEqual(
            BiliAdapter.buildPageListUrl(apiBase: "https://api.bilibili.com", bvid: "BV1xx411c7mD"),
            "https://api.bilibili.com/x/player/pagelist?bvid=BV1xx411c7mD")
    }

    /// pagelist 解析：cid/page/part 正常映射，顺序保持
    func testParsePageListMapsCidPagePart() throws {
        let json: [String: Any] = [
            "data": [
                ["cid": 100861, "page": 1, "part": "第1集 楔子"],
                ["cid": 100862, "page": 2, "part": "第2集 风起"],
            ]
        ]
        let pages = try BiliAdapter.parsePageList(json)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].cid, 100861)
        XCTAssertEqual(pages[0].page, 1)
        XCTAssertEqual(pages[0].part, "第1集 楔子")
        XCTAssertEqual(pages[1].cid, 100862)
        XCTAssertEqual(pages[1].part, "第2集 风起")
    }

    /// pagelist 解析：cid 非法项过滤、part 缺省 P<n>、page 缺省按序号
    func testParsePageListFiltersInvalidAndDefaults() throws {
        let json: [String: Any] = [
            "data": [
                ["page": 1, "part": "有 part 无 cid（非法项，过滤）"],
                ["cid": 200001],
                ["cid": 200002, "page": 3, "part": "  含空白待 trim  "],
            ]
        ]
        let pages = try BiliAdapter.parsePageList(json)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].cid, 200001)
        XCTAssertEqual(pages[0].page, 2, "page 缺省应按数组序号回填（i+1=2，非 p[\"page\"] 的 1）")
        XCTAssertEqual(pages[0].part, "P2", "part 缺省应回填 P<序号>")
        XCTAssertEqual(pages[1].part, "含空白待 trim", "part 应 trim 首尾空白")
    }

    /// pagelist 解析：缺 data 字段 / 全非法项 → 抛错（不得返回空数组静默通过）
    func testParsePageListThrowsOnMalformed() {
        XCTAssertThrowsError(try BiliAdapter.parsePageList([:]),
                             "缺 data 字段必须抛错")
        XCTAssertThrowsError(try BiliAdapter.parsePageList(["data": []]),
                             "空 data 数组必须抛错（playablePages 据此走 view 兜底）")
        XCTAssertThrowsError(try BiliAdapter.parsePageList(["data": [["page": 1]]]),
                             "全部项 cid 非法视同空列表，必须抛错")
    }

    // MARK: - 反馈 3 · 播放链路接线形态守卫

    /// PlaybackRepository BILI 分支必须走 playablePages（缓存→pagelist→view 兜底），
    /// 不得退回每章拉 view 的旧路径（412 风控主消耗方）
    func testPlaybackRepositoryUsesPlayablePages() {
        let src = Self.loadSource("TingYou/Services/PlaybackRepository.swift")
        XCTAssertFalse(src.contains("videoInfo(bvid:"), "BILI 分支不得直接调 videoInfo（旧 412 路径）")
        XCTAssertTrue(src.contains("playablePages(bvid:"), "BILI 分支必须经 playablePages 复合入口取分P")
    }

    // build 45 · 反馈 3：悦听（ytysxs）全链摘除——反馈 2 的两个用例
    //（发现页验证 sheet 重放 / WebView cookie 轮询）所守卫的
    // YtysxsVerifySheet / YtysxsVerifyWebView / antibotKeyword 闭环已整体
    // 删除（源文件不复存在），用例一并移除（替代守卫：Build45FeedbackTests
    // 的 testYtysxsFullyRemovedGuard 断言「源不存在」）。

    // MARK: - 反馈 5 · 听友FM TLS 错误人话映射

    /// TLS 握手失败（外部间歇性问题，客户端不可根治）必须映射为人话 +
    /// 规避建议，不得把 OSStatus 原文直接甩给用户
    func testDiscoverViewModelMapsSecureConnectionFailed() {
        let src = Self.loadSource("TingYou/UI/Discover/DiscoverViewModel.swift")
        XCTAssertTrue(src.contains(".secureConnectionFailed"), "必须识别 URLError.secureConnectionFailed")
        XCTAssertTrue(src.contains("安全连接失败"), "TLS 错误必须有人话文案（含换音源规避建议）")
    }

    // MARK: - 反馈 4 · 历史搜索滚动展示

    /// 历史搜索放开显示：ScrollView 滚动展示全部记录（上限 200pt 高度），
    /// 单条 chips 不再 lineLimit(1) 截断（fixedSize 允许换行）。
    /// 存储层 SearchHistoryStore 无显示截断（limit=20 去重置顶）——
    /// 截断只在显示层，本守卫钉住显示层新形态。
    func testHistorySectionScrollsAllEntries() {
        let src = Self.loadSource("TingYou/UI/Discover/DiscoverScreen.swift")
        // 提取 historySection 函数段（从声明到下一个 private func）
        guard let start = src.range(of: "privatevarhistorySection"),
              let rest = src[start.upperBound...].range(of: "privatefunc") else {
            XCTFail("historySection 函数段未找到——发现页结构变化时请同步修正本测试")
            return
        }
        let section = String(src[start.lowerBound..<rest.lowerBound])
        // build 47 · 布局返修：历史区高度自适应——≤8 条直接渲染（自然高度，
        // 1 条只占一行高），>8 条包 ScrollView 固定高 160。b44~b46 的
        // ScrollView + frame(maxHeight:) 形态被证伪：ScrollView 纵向贪婪，
        // 内容再少也占满 160pt——「最近搜索与书库之间空白过大」的真根因。
        XCTAssertTrue(section.contains("history.count<=8"), "历史区必须按条数分流：≤8 条自然高度（build 47 空白过大返修核心）")
        XCTAssertTrue(section.contains("ScrollView{historyList}"), ">8 条必须包 ScrollView 可滚动看全部记录")
        XCTAssertTrue(section.contains("frame(height:160)"), "滚动分支必须有固定高度上限（防历史过多挤压书库列表）")
        XCTAssertFalse(section.contains("maxHeight:"), "maxHeight 贪婪形态不得回归（ScrollView 纵向占满上限，少历史时撑空白）")
        // build 45 · CI 第一轮（反馈 2）：删除 b44 的两条对立断言（不得
        // lineLimit(1) / 不得 fixedSize）——b44 换行方案已被竖排回归证伪，
        // b45 回归 lineLimit(1) + 整体 fixedSize 横排形态，权威守卫在
        // Build45FeedbackTests.testHistoryChipsHorizontalLayoutGuard。
    }

    // MARK: - 工具

    /// 读源码文件并归一化（剔除整行注释 + whitespace 连接），口径与
    /// Build29RegressionTests.testKeyboardDismissGestureFormGuards 一致。
    private static func loadSource(_ rel: String) -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        guard FileManager.default.fileExists(atPath: path) else {
            fatalError("\(rel) 不存在：\(path)——路径布局变化时请同步修正本测试")
        }
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            fatalError("\(rel) 不可读：\(path)")
        }
        let codeOnly = src.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
        return codeOnly.components(separatedBy: .whitespacesAndNewlines).joined()
    }
}
