import XCTest
@testable import TingYou

/// build 48 · 四项需求守卫。
///
/// 需求 1 · 历史搜索「聚焦才显示 + 全量换行显示」（核心断言在
///   Build32RegressionTests.testDiscoverHistoryVisibilityFocusDriven 与
///   Build44/45 的历史区守卫，本文件补边界形态）；
/// 需求 2 · 删除发现页「分类：热门推荐」按钮 → 横向分类标签栏常驻
///   （音源切换联动）；
/// 需求 3 · 删除书架页「导入」tab（含「暂无导入书籍」空态页）；
/// 需求 4 · B站取流超时：backup 镜像自动重试 + watchdog 区分
///   「零字节挂起」与「慢速有数据」两种停滞形态。
///
/// 沙箱无 Swift 工具链，运行时行为（AVFoundation 就绪、镜像可达性）由真机
/// 复测与 CI 兜底；此处锁定可静态验证的接线面与纯判定函数。
final class Build48FeatureTests: XCTestCase {

    // MARK: - 需求 2 · 分类标签栏常驻（删除「分类：热门推荐」按钮）

    /// 需求 2 守卫：折叠面板与入口按钮形态必须消失，横向分类标签栏必须常驻，
    /// 且样式沿用原展开态蓝框（选中粗体主色 / 未选中次级色），
    /// 音源切换后标签栏随之刷新（选中项重置 + 分类源取自当前 browseSource）。
    func testDiscoverCategoryBarAlwaysVisible() {
        let src = Self.codeOnly(Self.loadSource("TingYou/UI/Discover/DiscoverScreen.swift"))
        // 折叠面板与入口按钮形态消失
        XCTAssertFalse(src.contains("DisclosureGroup"),
                       "分类折叠面板必须已删除（build 48 需求 2）")
        XCTAssertFalse(src.contains("categoryExpanded"),
                       "categoryExpanded 展开态必须已删除（build 48 需求 2）")
        XCTAssertFalse(src.contains("Text(\"分类："),
                       "「分类：xxx」入口按钮必须已删除（build 48 需求 2）")
        // 横向分类标签栏常驻
        XCTAssertTrue(src.contains("ScrollView(.horizontal, showsIndicators: false)"),
                      "分类标签栏必须横向滚动常驻（build 48 需求 2）")
        XCTAssertTrue(src.contains("ForEach(categories) { cat in"),
                      "分类标签栏必须遍历当前音源的分类（build 48 需求 2）")
        XCTAssertTrue(src.contains("Button(cat.name)"),
                      "每个分类标签必须可点（build 48 需求 2）")
        XCTAssertTrue(src.contains("selectedCategoryId = cat.id"),
                      "点击分类必须切换选中分类并重载（build 48 需求 2）")
        // 样式沿用原展开态蓝框
        XCTAssertTrue(src.contains(".fontWeight(selectedCategoryId == cat.id ? .bold : .regular)"),
                      "选中分类必须粗体、未选中常规（沿用原展开态样式）")
        XCTAssertTrue(src.contains(".foregroundStyle(selectedCategoryId == cat.id ? .primary : .secondary)"),
                      "选中分类必须主色、未选中次级色（沿用原展开态样式）")
        // 音源切换联动
        XCTAssertTrue(src.contains("private var categories: [DiscoverCategory]"),
                      "分类数据源必须取自当前 browseSource")
        XCTAssertTrue(src.contains("selectedCategoryId = DiscoverCatalog.categories(for: src).first?.id ?? \"\""),
                      "切换音源必须重置选中分类（标签栏随音源刷新）")
    }

    // MARK: - 需求 4 · B站取流超时：镜像自动重试 + 两种停滞形态区分

    /// 需求 4 守卫（接线面）：resolve 阶段一次取回「主选 + backup 镜像链」，
    /// watchdog 超时后自动切镜像重试（上限 3 次），链耗尽才报错；
    /// b47 的 Content-Type 改写 / ftyp 嗅探 / Referer+Range 注入不得回退。
    func testBiliMirrorRetryChainGuard() {
        let pm = Self.codeOnly(Self.loadSource("TingYou/Playback/PlaybackManager.swift"))
        let repo = Self.codeOnly(Self.loadSource("TingYou/Services/PlaybackRepository.swift"))
        let adapter = Self.codeOnly(Self.loadSource("TingYou/Services/BiliAdapter.swift"))
        // ① 候选链：主选 + backup 镜像
        XCTAssertTrue(repo.contains("func getPlayUrlCandidates"),
                      "仓储层必须提供候选链接口（主选 + backup 镜像）")
        XCTAssertTrue(pm.contains("getPlayUrlCandidates"),
                      "取流必须走候选链接口（build 48 需求 4）")
        XCTAssertTrue(pm.contains("storeMirrorChain(Array(playUrls.dropFirst()))"),
                      "backup 镜像必须入链备用（build 48 需求 4）")
        XCTAssertTrue(adapter.contains("func audioStreamUrlCandidates"),
                      "适配层必须返回多镜像候选（build 48 需求 4）")
        XCTAssertTrue(adapter.contains("func selectStreamUrlCandidates"),
                      "轨道选择必须返回候选链（build 48 需求 4）")
        XCTAssertTrue(adapter.contains("func deduplicatedUrls"),
                      "候选链必须去重（build 48 需求 4）")
        // ② watchdog 超时切镜像（至少 1 次，上限 3 次）
        XCTAssertTrue(pm.contains("static let mirrorRetryLimit = 3"),
                      "镜像重试上限必须为 3 次（build 48 需求 4）")
        XCTAssertTrue(pm.contains("func takeNextMirrorCandidate"),
                      "必须实现镜像候选出队（build 48 需求 4）")
        XCTAssertTrue(pm.contains("func handleStreamWatchdogFired"),
                      "watchdog 必须走统一处置入口（build 48 需求 4）")
        XCTAssertTrue(pm.contains("自动切换镜像第"),
                      "切镜像必须落到诊断文案（build 48 需求 4）")
        XCTAssertTrue(pm.contains("keepMirrorChain"),
                      "切镜像后重建条目必须保留镜像链（build 48 需求 4）")
        XCTAssertTrue(pm.contains("storeResolved(key: uri, url: next)"),
                      "切镜像必须重定向占位 URI 缓存（build 48 需求 4）")
        // ③ 两种停滞形态区分 + 诊断文案标注
        XCTAssertTrue(pm.contains("static let streamProgressFloorBytes: Int64 = 16 * 1024"),
                      "渐进判定阈值必须为 16KB（build 48 需求 4）")
        XCTAssertTrue(pm.contains("case progressing"),
                      "必须有「数据在缓慢到达」判定分支（build 48 需求 4）")
        XCTAssertTrue(pm.contains("case stalledNoData"),
                      "必须有「零字节挂起」判定分支（build 48 需求 4）")
        XCTAssertTrue(pm.contains("case stalledAfterData"),
                      "必须有「中途停滞」判定分支（build 48 需求 4）")
        XCTAssertTrue(pm.contains("零字节到达"),
                      "诊断文案必须标注零字节形态（build 48 需求 4）")
        XCTAssertTrue(pm.contains("数据中途停滞"),
                      "诊断文案必须标注中途停滞形态（build 48 需求 4）")
        XCTAssertTrue(pm.contains("数据缓慢到达"),
                      "诊断文案必须标注慢速到达形态（build 48 需求 4）")
        XCTAssertTrue(pm.contains("var totalForwardedBytes: Int64"),
                      "代理层必须累计净转发字节（偏移对齐丢弃后）")
        XCTAssertTrue(pm.contains("func resetForwardedBytes"),
                      "换条目必须重置字节计数（build 48 需求 4）")
        // ④ b47 不得回退：Content-Type 改写 / ftyp 嗅探 / Referer+Range 注入
        XCTAssertTrue(pm.contains("static func rewrittenBiliContentType"),
                      "b47 Content-Type 改写不得回退")
        XCTAssertTrue(pm.contains("static func sniffedBiliMp4Mime"),
                      "b47 ftyp 嗅探不得回退")
        XCTAssertTrue(pm.contains("static func applyBiliCdnHeaders"),
                      "b47 Referer/Range 注入不得回退")
    }

    /// 需求 4 守卫（纯判定函数）：watchdog 到点时按「本观察窗净转发字节增量」
    /// 二分——增量 ≥ 16KB 判 progressing（延长观察，不切镜像）；否则零字节判
    /// stalledNoData（真挂起，切镜像），有历史字节判 stalledAfterData
    /// （中途停滞，切镜像）。
    func testStreamStallVerdictDistinguishesTwoStallShapes() {
        // ① 数据在缓慢到达：增量达到阈值 → 延长观察
        XCTAssertEqual(PlaybackManager.streamStallVerdict(previousBytes: 0, currentBytes: 16 * 1024),
                       .progressing(deltaBytes: 16 * 1024))
        // ② 20s 内零字节到达 → 真挂起，切镜像
        XCTAssertEqual(PlaybackManager.streamStallVerdict(previousBytes: 0, currentBytes: 0),
                       .stalledNoData)
        // ③ 曾有数据、中途停滞 → 与挂起等价处理（切镜像），仅文案区分
        XCTAssertEqual(PlaybackManager.streamStallVerdict(previousBytes: 4096, currentBytes: 4096),
                       .stalledAfterData(forwardedBytes: 4096))
        // 边界：16383 < 16384 → 不算渐进（按停滞处理）
        XCTAssertEqual(PlaybackManager.streamStallVerdict(previousBytes: 0, currentBytes: 16 * 1024 - 1),
                       .stalledAfterData(forwardedBytes: 16 * 1024 - 1))
        // 二次观察窗：基线推进后按新基线重新判定（延长观察链路）
        XCTAssertEqual(PlaybackManager.streamStallVerdict(previousBytes: 32 * 1024,
                                                          currentBytes: 32 * 1024 + 16 * 1024),
                       .progressing(deltaBytes: 16 * 1024))
        // 零字节且基线为 0 → 仍是零字节形态（不得误判为中途停滞）
        XCTAssertEqual(PlaybackManager.streamStallVerdict(previousBytes: 0, currentBytes: 0),
                       .stalledNoData)
    }

    // MARK: - 需求 3 · 书架导入 tab 删除（边界口径）

    /// 需求 3 边界守卫：导入 tab / 空态页 / 导入列表视图必须消失，
    /// 收藏与历史两 tab 必须保留；外部导入入口（本地/网页导入菜单）
    /// 属「我的」能力链，按组长指令不在本次删除范围，必须保留。
    func testShelfImportTabRemovedButExternalImportKept() {
        let src = Self.codeOnly(Self.loadSource("TingYou/UI/Shelf/ShelfScreen.swift"))
        XCTAssertFalse(src.contains("importedContent"), "导入 tab 内容卡片必须已删除")
        XCTAssertFalse(src.contains("暂无导入书籍"), "导入空态页必须已删除")
        XCTAssertFalse(src.contains("ImportedBookRow"), "导入行视图必须已删除")
        XCTAssertFalse(src.contains("ImportedBookGridItem"), "导入网格项视图必须已删除")
        XCTAssertFalse(src.contains("selectedTab == 2"), "不得残留第三 tab 分支")
        XCTAssertTrue(src.contains("favoritesContent"), "收藏 tab 必须保留")
        XCTAssertTrue(src.contains("historyContent"), "历史 tab 必须保留")
    }

    // MARK: - 工具

    /// 读工程源码（相对工程根的路径），口径与 Build29RegressionTests 一致。
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
        return src
    }

    /// 剔除整行注释（trim 后以 // 开头）——删除说明注释里含被断言的标识符名，
    /// 参与判定前必须剔除。
    private static func codeOnly(_ src: String) -> String {
        src.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }
}
