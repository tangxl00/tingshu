import XCTest
@testable import TingYou

/// build 29 · 回归测试（R1-R8）。
/// 验证新增两源未破坏既有源行为与 v1.3.4 调整；
/// build 36：听吧（ting08）下架后的源清单口径同步；
/// build 37 · 反馈 1：听十五（ting15）/ 书音FM（mekui）下架后的源清单口径同步。
final class Build29RegressionTests: XCTestCase {

    // MARK: - R1-R4 · 聚合搜索源列表包含既有源（结构存在性，非网络测试）

    func testAggregateSearchSourcesIncludeLegacySources() {
        let sources = SourceEnabledStore.searchSources
        XCTAssertTrue(sources.contains(SourceRegistry.TINGYOU), "听友FM 必须在搜索源列表中")
        XCTAssertTrue(sources.contains(SourceRegistry.YTYXSX), "悦听有声书 必须在搜索源列表中")
        // build 36 · 反馈 4：听吧（ting08）已下架——不得再出现在搜索源列表
        XCTAssertFalse(sources.contains("ting08"), "听吧已下架，不得残留在搜索源列表中")
        // build 37 · 反馈 1：听十五/书音FM 已下架——不得再出现在搜索源列表
        XCTAssertFalse(sources.contains("ting15"), "听十五已下架，不得残留在搜索源列表中")
        XCTAssertFalse(sources.contains("mekui"), "书音FM 已下架，不得残留在搜索源列表中")
    }

    func testAggregateSearchSourcesIncludeNewSources() {
        let sources = SourceEnabledStore.searchSources
        XCTAssertTrue(sources.contains(SourceRegistry.BILI), "B站 必须在搜索源列表中")
        // build 38 · 反馈 1：ting59（59听书网）下架——不得残留在搜索源列表中
        XCTAssertFalse(sources.contains("ting59"), "59听书网已下架，不得残留在搜索源列表中")
    }

    // MARK: - R5 · PlaybackManager prepareQueue 接口未变（结构存在性）

    func testPlaybackManagerPrepareQueueSignatureUnchanged() {
        // 通过构造验证：若接口签名变化，此行编译失败
        let manager = PlaybackManager(playbackRepository: makeDummyRepo())
        let album = Album(albumId: 1, title: "测试", author: nil, teller: nil,
                          coverUrl: nil, intro: nil, category: nil, categoryId: nil,
                          type: nil, typeId: nil, status: nil, chapterCount: nil,
                          updatedAt: nil, playCount: nil, available: true,
                          source: SourceRegistry.TINGYOU, detailPath: nil)
        let chapter = Chapter(chapterId: 1, index: 0, title: "第一回", durationSec: nil)
        // 编译通过即证明接口未变；不实际播放
        manager.prepareQueue(album: album, chapters: [chapter], startIdx: 0, startPosMs: 0)
        XCTAssertNotNil(manager)
    }

    // MARK: - R6-R7 · 旧白名单未丢

    func testLegacyPinningDomainsStillAllowed() {
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("m.ting15.com"), "ting15 旧白名单不得丢失")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("www.ting08.com"), "ting08 旧白名单不得丢失")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("www.ytysxs.com"), "悦听旧白名单不得丢失")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("mp3.ytysxs.top"), "悦听音频旧白名单不得丢失")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("m.mekui.com"), "书音FM 旧白名单不得丢失")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("tingyou.fm"), "听友FM 旧白名单不得丢失")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("guoguo.org.cn"), "guoguo 旧白名单不得丢失")
    }

    // MARK: - R8 · 导入书数据模型对既有源仍正常读写（meta 字段 lightweight migration）

    func testImportedBookModelMetaFieldExistsAndDefaultsNil() {
        let book = ImportedBookModel(id: 1, title: "测试", kind: "ytysxs")
        XCTAssertNil(book.meta, "meta 字段必须默认为 nil")
        XCTAssertEqual(book.kind, "ytysxs")
        XCTAssertEqual(book.title, "测试")
    }

    func testImportedBookModelCanStoreMeta() {
        let book = ImportedBookModel(id: 2, title: "测试", kind: "bili", meta: "UP主名")
        XCTAssertEqual(book.meta, "UP主名")
    }

    // MARK: - SourceRegistry 新源注册未破坏旧源

    func testSourceRegistryDisplayNamesUnchanged() {
        XCTAssertEqual(SourceRegistry.displayName(src: "tingyou"), "听友FM")
        XCTAssertFalse(SourceRegistry.isKnown(src: "ting08"), "听吧已下架，不应再注册为已知源")
        XCTAssertEqual(SourceRegistry.displayName(src: "ytysxs"), "悦听有声书")
        // build 37 · 反馈 1：听十五/书音FM 下架——不再注册，显示名回落原始 id
        XCTAssertFalse(SourceRegistry.isKnown(src: "ting15"), "听十五已下架，不应再注册为已知源")
        XCTAssertFalse(SourceRegistry.isKnown(src: "mekui"), "书音FM 已下架，不应再注册为已知源")
        XCTAssertEqual(SourceRegistry.displayName(src: "ting15"), "ting15", "下架源显示名回落原始 id")
        XCTAssertEqual(SourceRegistry.displayName(src: "mekui"), "mekui", "下架源显示名回落原始 id")
    }

    func testSourceRegistryNewSourcesRegistered() {
        XCTAssertEqual(SourceRegistry.displayName(src: "bili"), "B站")
        XCTAssertTrue(SourceRegistry.isKnown(src: "bili"))
        // build 38 · 反馈 1：ting59（59听书网）下架——显示名回落原始 id、isKnown 翻转
        XCTAssertEqual(SourceRegistry.displayName(src: "ting59"), "ting59", "下架源显示名回落原始 id")
        XCTAssertFalse(SourceRegistry.isKnown(src: "ting59"), "59听书网已下架")
    }

    /// build 37 · 反馈 1：ting15/mekui 下架后 MSRC 注册表清空（同 build 36 删 ting08 口径）。
    func testMsrcSourcesDelisted() {
        XCTAssertNil(SourceRegistry.configOf(src: "ting08"), "听吧已下架，config 不得残留")
        XCTAssertNil(SourceRegistry.configOf(src: "ting15"), "听十五已下架，config 不得残留")
        XCTAssertNil(SourceRegistry.configOf(src: "mekui"), "书音FM 已下架，config 不得残留")
        XCTAssertNil(SourceRegistry.configOf(src: "bili"), "B站不应进入 msrcSources")
        XCTAssertNil(SourceRegistry.configOf(src: "ting59"), "ting59 不应进入 msrcSources")
        XCTAssertTrue(SourceRegistry.msrcSources.isEmpty, "MSRC 注册表应已清空")
    }

    // MARK: - 版本号断言

    /// v1.4.2 · P2-2（质检）：原断言为 `XCTAssertTrue(true, …)` 恒真——不读文件不校验值，
    /// 版本号忘改也照常绿，防线形同虚设。重建为真读真比：经 `#filePath` 相对定位
    /// `ios/TingYou/project.yml`（测试文件在 TingYouTests/ 下，上溯两级即工程目录，
    /// 与 CI checkout 布局一致），逐行解析 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
    /// 首个定义并断言精确值。版本号忘改或格式漂移即测试红（CI 兜底）。
    /// v1.4.4：断言值随 build 37 同步升位（1.4.4 / 37）。
    func testMarketingVersionIs144() {
        // #filePath = …/ios/TingYou/TingYouTests/Build29RegressionTests.swift
        // 上溯两级：TingYouTests → TingYou（project.yml 所在，与 xcodegen 读取位置一致）
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let ymlPath = projectDir + "/project.yml"

        guard FileManager.default.fileExists(atPath: ymlPath) else {
            XCTFail("project.yml 不存在：\(ymlPath)——路径布局变化时请同步修正本测试")
            return
        }
        guard let yml = try? String(contentsOfFile: ymlPath, encoding: .utf8) else {
            XCTFail("project.yml 不可读：\(ymlPath)")
            return
        }
        XCTAssertEqual(Self.yamlFirstValue(of: "MARKETING_VERSION", in: yml), "1.4.4",
                       "project.yml MARKETING_VERSION 必须为 1.4.4（升版本时同步改此断言）")
        XCTAssertEqual(Self.yamlFirstValue(of: "CURRENT_PROJECT_VERSION", in: yml), "41",
                       "project.yml CURRENT_PROJECT_VERSION 必须为 41（升版本时同步改此断言）")
    }

    /// build 39-41 · 回归守卫：键盘收焦与点书导航的形态约束（防 build 37/39/40
    /// 三轮真机回归复发）。
    /// build 37 形态（禁①）：容器级「contentShape(Rectangle()) + 父级 onTapGesture」
    /// 整体包裹——父手势抢占行点击 + contentShape 整域命中引入几何漂移。
    /// build 39 形态（禁②）：List 本体直接挂 onTapGesture——tap 抢占行内
    /// NavigationLink 激活（点书=键盘收起+无导航）。
    /// build 41 形态约束（发现页专用，针对第 5 轮系统性根因「@FocusState 状态翻转
    /// 收焦触发全 body 重渲染、丢弃进行中的行激活」）：
    /// 禁④ 发现页使用 @FocusState；要求⑤ 收焦必须是 UIKit resignFirstResponder
    ///（零重渲染）；要求⑥ 发现页 List 本体不挂任何手势（收焦只挂外层一处
    /// 容器级 simultaneousGesture，精确 1 处）；scrollDismissesKeyboard ≥2 保留。
    /// SearchScreen 无 @FocusState、收焦本就是 resignFirstResponder，保持
    /// b40 形态约束（禁①② + simultaneousGesture ≥1）。
    /// 判定：各文件剔除整行注释后按 whitespace 归一化，逐项断言。
    func testKeyboardDismissGestureFormGuards() {
        // #filePath = …/TingYouTests/Build29RegressionTests.swift，
        // 上溯两级：TingYouTests → TingYou（工程目录，与 testMarketingVersionIs144 同款定位）
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        for rel in ["TingYou/UI/Discover/DiscoverScreen.swift",
                    "TingYou/UI/Search/SearchScreen.swift"] {
            let srcPath = projectDir + "/" + rel
            guard FileManager.default.fileExists(atPath: srcPath) else {
                XCTFail("\(rel) 不存在：\(srcPath)——路径布局变化时请同步修正本测试")
                return
            }
            guard let src = try? String(contentsOfFile: srcPath, encoding: .utf8) else {
                XCTFail("\(rel) 不可读：\(srcPath)")
                return
            }
            // 归一化前先剔除整行注释（trim 后以 // 开头）：注释行夹在修饰链中间
            // 会把链拆断，导致旧形态漏检（build 39 阴性对照实测暴露此缺陷）；
            // 行尾内联注释不影响下方各匹配（均以 ASCII '.' 前缀锚定，注释文字无该前缀）。
            let codeOnly = src.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") }
                .joined(separator: "\n")
            let normalized = codeOnly
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            let isDiscover = rel.hasSuffix("DiscoverScreen.swift")
            // 禁①容器级包裹（build 37 形态）
            XCTAssertFalse(
                normalized.contains(".contentShape(Rectangle()).onTapGesture"),
                "\(rel)：禁止 contentShape(Rectangle()) 紧跟 onTapGesture 的容器级收焦包裹（build 37 真机回归：点书无反应 + 布局穿透 tab bar）")
            // 禁②List 直接挂 tap（build 39 形态：List 修饰链上的 onTapGesture）
            XCTAssertFalse(
                normalized.contains(".scrollDismissesKeyboard(.immediately).onTapGesture"),
                "\(rel)：禁止 List 本体直接挂 onTapGesture（build 39 真机回归：tap 抢占行内 NavigationLink，点书=收焦+无导航）；收焦必须用 simultaneousGesture")
            if isDiscover {
                // 禁④ build 41：@FocusState 状态翻转收焦触发全 body 重渲染，
                // 键盘弹起时点书行的导航激活被同帧布局扰动丢弃（第 5 轮根因）。
                XCTAssertFalse(
                    normalized.contains("@FocusState"),
                    "发现页禁止使用 @FocusState 收焦（build 41 根因：状态翻转触发全 body 重渲染，丢弃进行中的 NavigationLink 行激活）；收焦必须走 UIKit resignFirstResponder")
                // 要求⑤ resignFirstResponder 收焦形态（与搜索页对齐、零重渲染）
                XCTAssertTrue(
                    normalized.contains("resignFirstResponder"),
                    "发现页收焦必须使用 resignFirstResponder（零重渲染，不打断行导航激活）")
                // 禁⑥ List 本体挂手势（含 simultaneousGesture——build 40 形态，
                // 虽然 simultaneous 不抢行点击，但统一收敛到外层一处更可控）
                XCTAssertFalse(
                    normalized.contains(".scrollDismissesKeyboard(.immediately).simultaneousGesture("),
                    "发现页 List 本体禁止挂任何手势（build 41 形态：收焦只挂内容区外层一处容器级 simultaneousGesture）")
                // 要求⑥ 外层容器级手势恰 1 处
                XCTAssertEqual(
                    normalized.components(separatedBy: ".simultaneousGesture(").count - 1, 1,
                    "发现页收焦手势必须恰为外层容器级 1 处 simultaneousGesture（多处分挂是 build 40 形态，已收敛）")
                // 两个 List 的滚动收起保留
                let scrollCount = normalized.components(separatedBy: ".scrollDismissesKeyboard").count - 1
                XCTAssertGreaterThanOrEqual(scrollCount, 2,
                    "发现页两个 List 的滚动收起（scrollDismissesKeyboard）不得少于 2 处")
            } else {
                // SearchScreen：保持 b40 形态（resign + List simultaneousGesture，真机无投诉）
                let actual = normalized.components(separatedBy: ".simultaneousGesture(").count - 1
                XCTAssertGreaterThanOrEqual(
                    actual, 1,
                    "\(rel)：.simultaneousGesture( 不得少于 1 处（List 本体收焦）")
            }
        }
    }

    /// 从缩进 YAML 文本提取 `key: value` 首个定义的值：
    /// 按行前缀精确匹配（trim 缩进后 `key:` 开头，不会误匹配同前缀长键），
    /// 取值 trim、去行内 ` #` 注释、去成对引号。
    /// project.yml 中两键均唯一定义（见沙箱 Python 模拟验证），取首行即正确。
    private static func yamlFirstValue(of key: String, in yml: String) -> String? {
        for rawLine in yml.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(key + ":") else { continue }
            var value = String(line.dropFirst(key.count + 1))
                .trimmingCharacters(in: .whitespaces)
            if let commentRange = value.range(of: " #") {
                value = String(value[..<commentRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
               || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - 辅助

    private func makeDummyRepo() -> PlaybackRepository {
        PlaybackRepository(
            apiClient: APIClient(),
            ytysxsAdapter: YtysxsAdapter(apiClient: APIClient()),
            biliAdapter: BiliAdapter()
        )
    }
}
