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
        // build 45 · 反馈 3：悦听（ytysxs）已下架——不得再出现在搜索源列表
        XCTAssertFalse(sources.contains("ytysxs"), "悦听已下架，不得残留在搜索源列表中")
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

    /// build 51（质检必修 · 音源残留）：本用例此前断言「已下架源的旧白名单不得丢失」，
    /// 与「收敛白名单」直接冲突——已下架站点没有任何在役请求，留着精确域等于给它们
    /// 保留出站许可。现反转为「必须已摘除」，并补在役三源 + 云同步的放行断言（防收敛过头）。
    func testDelistedSourcePinningDomainsRejected() {
        // 已下架源（听十五 / 听吧 / 书音FM 及其图床音频域 / 书音FM OSS）——7 条精确域必须摘除
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("m.ting15.com"), "听十五已下架，pin 白名单必须摘除")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("www.ting08.com"), "听吧已下架，pin 白名单必须摘除")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("m.mekui.com"), "书音FM 已下架，pin 白名单必须摘除")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("api.mekui.com"), "书音FM 已下架，pin 白名单必须摘除")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("api.aikeu.com"), "书音FM 图床已下架，pin 白名单必须摘除")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("mp3.aikeu.com"), "书音FM 音频域已下架，pin 白名单必须摘除")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("shuyinfm.oss-cn-hangzhou.aliyuncs.com"),
                       "书音FM OSS 已下架，pin 白名单必须摘除")
        // build 45 · 反馈 3：悦听下架——pin 白名单域名同步摘除（不再需要证书锁定）
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("www.ytysxs.com"), "悦听已下架，域名应已从 pin 白名单摘除")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("mp3.ytysxs.top"), "悦听音频域名应已从 pin 白名单摘除")
        // 在役三源 + 云同步仍须放行（收敛不能过头）
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("file.hgeuz.cn"), "听友FM 文件域仍在役")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("tingyou.fm"), "听友FM 旧白名单不得丢失")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("guoguo.org.cn"), "guoguo 旧白名单不得丢失")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("www.yitingshu.com"), "易听书站必须放行")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("aod.cos.tx.xmcdn.com"), "易听书音频 CDN 必须放行")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("imagev2.xmcdn.com"), "易听书封面域必须放行")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("tingshu-d2gjera4688800c8e.service.tcloudbase.com"),
                      "云同步域必须放行")
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
        // build 45 · 反馈 3：悦听下架——isKnown 翻转、显示名回落原始 id（同 ting15/mekui/ting59 口径）
        XCTAssertFalse(SourceRegistry.isKnown(src: "ytysxs"), "悦听已下架，不应再注册为已知源")
        XCTAssertEqual(SourceRegistry.displayName(src: "ytysxs"), "ytysxs", "悦听下架后显示名回落原始 id")
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
        // build 50：易听书注册进 MSRC（对齐 PC 三源基准），注册表不再为空
        XCTAssertNotNil(SourceRegistry.msrcSources[SourceRegistry.YITINGSHU], "易听书应注册进 MSRC")
        XCTAssertEqual(SourceRegistry.msrcSources.count, 1, "MSRC 仅易听书一个源（bili 走专用适配器不进 MSRC）")
    }

    // MARK: - 版本号断言

    /// v1.4.2 · P2-2（质检）：原断言为 `XCTAssertTrue(true, …)` 恒真——不读文件不校验值，
    /// 版本号忘改也照常绿，防线形同虚设。重建为真读真比：经 `#filePath` 相对定位
    /// `ios/TingYou/project.yml`（测试文件在 TingYouTests/ 下，上溯两级即工程目录，
    /// 与 CI checkout 布局一致），逐行解析 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
    /// 首个定义并断言精确值。版本号忘改或格式漂移即测试红（CI 兜底）。
    /// v1.4.4：断言值随之升位；build 53 返修升 CURRENT_PROJECT_VERSION → 53。
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
        XCTAssertEqual(Self.yamlFirstValue(of: "CURRENT_PROJECT_VERSION", in: yml), "53",
                       "project.yml CURRENT_PROJECT_VERSION 必须为 53（升版本时同步改此断言）")
    }

    /// build 39-41 · 回归守卫：键盘收焦与点书导航的形态约束（防 build 37/39/40
    /// 三轮真机回归复发）；build 43 · 依 CI 六用例证据收敛形态。
    /// build 37 形态（禁①）：容器级「contentShape(Rectangle()) + 父级 onTapGesture」
    /// 整体包裹——父手势抢占行点击 + contentShape 整域命中引入几何漂移。
    /// build 39 形态（禁②）：List 本体直接挂 onTapGesture——tap 抢占行内
    /// NavigationLink 激活（点书=键盘收起+无导航）。
    /// build 41/42 形态（禁⑦，由计数断言承担）：容器级 simultaneousGesture
    /// 挂在包住 List 的 if/else / Group / VStack 上——build 42 CI 六用例
    /// （XCUITest 真实点击）确证：任何形式的容器级 tap 手势都会杀死 List 内
    /// NavigationLink 行激活（A/B/D 失败；E 对照页无该手势导航正常）。
    /// build 43 形态约束（发现页专用；build 44 · 反馈 1 扩围后计数更新）：
    /// 禁④ @FocusState（build 41）→ build 48 · 需求 1 改写为「焦点态必须隔离
    /// 在叶子视图」：1 处状态声明 + 2 处 FocusState.Binding 下发，禁止主视图
    /// 直接读焦点态、禁止 onChange 监听焦点翻转；要求⑤ resignFirstResponder；
    /// 禁⑥ List 本体挂任何手势；要求⑦ .simultaneousGesture( 恰 0 处
    /// （build 45 全局化后清零）；要求⑧ .onTapGesture( 恰 0 处；
    /// scrollDismissesKeyboard ≥2 保留。
    /// 行点击收焦交给导航 push 本身（iOS 默认行为）。
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
                // build 48 · 需求 1：@FocusState 回归（仅驱动历史区显隐）。
                // build 41 的根因是「焦点状态翻转触发 DiscoverScreen 全 body
                // 重渲染，丢弃进行中的 NavigationLink 行激活」——b48 需求
                // 明确要求「聚焦才显示历史区」，故保留 @FocusState，但把焦点态
                // 的读写全部隔离进两个叶子视图（DiscoverSearchField /
                // DiscoverHistoryGate），主视图 body 只写不读焦点态。
                // 守卫：① @FocusState 声明形态固定（1 处状态 + 2 处 Binding
                // 下发）；② 状态名固定 searchFieldFocused；③ 禁止 onChange
                // 监听焦点翻转（build 41 根因链）；④ 禁止主视图直接以
                // searchFieldFocused 参与条件判断（读取只允许在叶子内）。
                let focusStateCount = normalized.components(separatedBy: "@FocusState").count - 1
                XCTAssertEqual(focusStateCount, 3,
                               "发现页 @FocusState 形态必须固定：1 处状态声明 + 2 处 FocusState.Binding 下发（build 48 需求 1 焦点隔离）")
                XCTAssertEqual(normalized.components(separatedBy: "@FocusStateprivatevar").count - 1, 1,
                               "焦点状态声明必须恰好 1 处（searchFieldFocused，仅驱动历史区显隐）")
                XCTAssertEqual(normalized.components(separatedBy: "@FocusState.Bindingvar").count - 1, 2,
                               "焦点状态必须以 FocusState.Binding 下发给叶子视图（搜索框 + 历史区门卫）")
                XCTAssertTrue(normalized.contains("searchFieldFocused:Bool"),
                              "焦点状态名必须为 searchFieldFocused")
                XCTAssertFalse(normalized.contains("onChange(of:searchFieldFocused"),
                               "禁止用 onChange 监听焦点翻转（build 41 根因链：状态翻转引发重渲染扰动行导航激活）")
                XCTAssertFalse(normalized.contains("ifsearchFieldFocused"),
                               "主视图不得直接以 searchFieldFocused 参与条件判断（焦点读取必须隔离在叶子视图内）")
                XCTAssertFalse(normalized.contains("&&searchFieldFocused"),
                               "主视图不得直接以 searchFieldFocused 参与条件判断（焦点读取必须隔离在叶子视图内）")
                XCTAssertFalse(normalized.contains("resignFirstResponder"),
                               "发现页不得自行收键盘（build 45 起统一走 window 级 recognizer，零重渲染）")
                // 禁⑥ List 本体挂手势（含 simultaneousGesture——build 40 形态，
                // 虽然 simultaneous 不抢行点击，但统一收敛到非祖先小视图更可控）
                XCTAssertFalse(
                    normalized.contains(".scrollDismissesKeyboard(.immediately).simultaneousGesture("),
                    "发现页 List 本体禁止挂任何手势（build 41 形态：收焦只挂非 List 祖先的小视图）")
                // 要求⑦（build 45 · 反馈 4 重写）：simultaneousGesture 必须为 0 处
                //——b43/b44 五处局部收焦挂载（搜索栏容器/分类行/错误占位区/
                // 间距区/历史区背景）全删，全局收焦改走 window 级 UIKit
                // recognizer（安装守卫见 testGlobalKeyboardDismissInstalled）。
                XCTAssertEqual(
                    normalized.components(separatedBy: ".simultaneousGesture(").count - 1, 0,
                    "发现页局部收焦手势必须为 0 处（build 45 全局化：window 级 recognizer 兜底）；容器级挂载（任何数量）都会杀死行 NavigationLink 激活（build 42 CI 六用例证据）")
                // 要求⑧（build 45 · 反馈 4 重写）：onTapGesture 必须为 0 处——
                // 局部收焦挂载清零（含 b44 历史区背景 onTap）。
                XCTAssertEqual(
                    normalized.components(separatedBy: ".onTapGesture").count - 1, 0,
                    "发现页 onTapGesture 必须为 0 处（build 45 全局化）；多出即形态漂移——List 本体或容器上挂 onTapGesture 是 build 37/39 真机回归形态")
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

    /// build 45 · 反馈 4 守卫：全局收键盘安装形态——window 级 UIKit 方案的
    /// 四要素必须齐备：① App 启动调用 installOnce；② UITapGestureRecognizer
    /// 挂 window；③ cancelsTouchesInView = false（不吞事件——与被证伪的
    /// SwiftUI 容器手势的本质差异，List 行导航照常激活）；④ endEditing 动作 +
    /// delegate 跳过 UITextField 命中（防「先收再聚焦」键盘闪烁）；⑤ 并行识别
    /// shouldRecognizeSimultaneouslyWith（CI 第一轮 C/新 G 失败根因：控件内部
    /// 手势独占认领把 window recognizer 排除，键盘永不收）。
    func testGlobalKeyboardDismissInstalled() {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let pairs: [(rel: String, needles: [String], what: String)] = [
            ("TingYou/App/TingYouApp.swift",
             ["GlobalKeyboardDismiss.installOnce()"],
             "App 启动必须安装全局收键盘 recognizer"),
            ("TingYou/App/GlobalKeyboardDismiss.swift",
             ["UITapGestureRecognizer",
              "cancelsTouchesInView = false",
              "endEditing",
              "UITextField",
              "UIGestureRecognizerDelegate",
              "shouldRecognizeSimultaneouslyWith"],
             "全局收键盘实现必须包含 window 级 recognizer 四要素"),
        ]
        for pair in pairs {
            let srcPath = projectDir + "/" + pair.rel
            guard FileManager.default.fileExists(atPath: srcPath) else {
                XCTFail("\(pair.rel) 不存在：\(srcPath)——路径布局变化时请同步修正本测试")
                return
            }
            guard let src = try? String(contentsOfFile: srcPath, encoding: .utf8) else {
                XCTFail("\(pair.rel) 不可读：\(srcPath)")
                return
            }
            for needle in pair.needles {
                XCTAssertTrue(src.contains(needle),
                               "\(pair.rel)：\(pair.what)——缺失 \(needle)")
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
        // build 45 · 反馈 3：悦听下架，PlaybackRepository init 3 → 2 参数。
        PlaybackRepository(
            apiClient: APIClient(),
            biliAdapter: BiliAdapter()
        )
    }
}
