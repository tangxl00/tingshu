import XCTest
@testable import TingYou

/// build 45 · 四项反馈修复的回归守卫（沙箱无 Swift 工具链——源码形态守卫
/// 沿用 Build29RegressionTests「剔除整行注释 + whitespace 归一化」口径，
/// CI 上由 xcodebuild 全量单测兜底）。
/// 1. B站错误透传链路（反馈 1a）：失败原文必须能从取流层一路传到 UI——
///    delegate 失败记录 → PlaybackManager 记录槽 → .failed 组合 player 层
///    原文 → 红字全文显示；重定向必须重注入 CDN 头（反馈 1b 设备侧缺口）。
/// 2. 历史搜索词条横排（反馈 2）：b44 的 fixedSize(horizontal:false) 竖排
///    形态必须消失，lineLimit(1) + 整体 fixedSize 形态必须存在。
/// 3. 悦听全链摘除（反馈 3）：Ytysxs* 文件与类型引用必须为零（存量书
///    describePlaybackError/kindLabel 字符串兼容除外）。
final class Build45FeedbackTests: XCTestCase {

    private static func loadSource(_ rel: String) -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(rel) 不可读：\(path)")
            return ""
        }
        return src
    }


    /// 剔除整行注释后的源码（沿用 Build29RegressionTests 守卫口径）：
    /// 「Ytysxs 全链摘除」「竖排形态消失」等否定断言必须在代码级判定，
    /// 不被「build 45 已删除 …」类说明注释误触发。
    private static func codeOnly(_ rel: String) -> String {
        let src = loadSource(rel)
        return src.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - 反馈 1 · B站错误透传链路

    /// 透传链四环：① proxy delegate 持 failureRecorder 闭包；② 4xx/网络错误
    /// 原文写入（「取流被拒 HTTP」）；③ 重定向回调重注入 applyBiliCdnHeaders
    /// （1b 缺口：URLSession 默认重定向不保证保留自定义头 → 镜像域 403）；
    /// ④ PlaybackManager 记录槽 record/take/clear 三方法 + .failed 组合
    /// player 层原文 + 「B站取证：截图反馈此段」指引。
    func testBiliErrorPassthroughChainGuards() {
        let pm = Self.loadSource("TingYou/Playback/PlaybackManager.swift")
        XCTAssertTrue(pm.contains("failureRecorder:"), "proxy delegate 必须持 failureRecorder 闭包（取流层失败原文入口）")
        XCTAssertTrue(pm.contains("recordLoaderFailure"), "PlaybackManager 必须有 recordLoaderFailure 记录槽")
        XCTAssertTrue(pm.contains("takeLoaderFailureRecord"), "必须有 takeLoaderFailureRecord（.failed 时取出并清槽）")
        XCTAssertTrue(pm.contains("clearLoaderFailureRecord"), "切章必须清记录槽（旧失败原文不得串章）")
        XCTAssertTrue(pm.contains("willPerformHTTPRedirection"), "proxy delegate 必须实现重定向回调")
        XCTAssertTrue(pm.contains("applyBiliCdnHeaders"), "重定向后必须重注入 B站 CDN 请求头（Referer/UA）")
        XCTAssertTrue(pm.contains("取流被拒 HTTP"), "取流 4xx 必须以人话 + 状态码原文记录")
        XCTAssertTrue(pm.contains("B站取证：截图反馈此段"), "失败文案必须带取证指引（用户截图即可定位坏在哪一层）")
    }

    /// 播放失败文案结构：人话 + [诊断] 分层原文（resolve · / play · / player ·），
    /// 拒绝只给「Cannot Open」。CI 第一轮 H 空窗补位（反馈 2）：取流看门狗 +
    /// 加载中间态 + 可断言锚（「暂停」accessibilityLabel——此前播放按钮只有
    /// SF Symbol，XCUITest 断言永不命中）。
    func testPlaybackErrorDiagnosticFormatGuard() {
        let pm = Self.loadSource("TingYou/Playback/PlaybackManager.swift")
        XCTAssertTrue(pm.contains("[诊断]"), "失败文案必须拼接 [诊断] 分段")
        XCTAssertTrue(pm.contains("resolve ·"), "resolve 阶段失败必须带阶段前缀原文")
        XCTAssertTrue(pm.contains("player ·"), "player 层失败必须带 AVFoundation NSError 原文段")
        // 反馈 2a/2b：中间态 + 看门狗（缓冲挂起不得静默 20s 以上）
        XCTAssertTrue(pm.contains("isChapterLoading"), "必须有章节加载中间态（H 空窗根因之一）")
        XCTAssertTrue(pm.contains("playbackWatchdog"), "必须有取流看门狗（缓冲挂起按失败透传）")
        XCTAssertTrue(pm.contains("取流超时"), "看门狗文案必须含「取流超时」人话")
        // 反馈 2c：PlayerScreen 可断言锚
        let ps = Self.loadSource("TingYou/UI/Player/PlayerScreen.swift")
        XCTAssertTrue(ps.contains("加载中…"), "PlayerScreen 必须显示加载中间态")
        XCTAssertTrue(ps.contains(#""暂停""#), "播放/暂停按钮必须有「暂停」accessibilityLabel（XCUITest 锚）")
    }

    // MARK: - 反馈 2 · 历史搜索词条横排

    /// b44 回归根因：chip 文字 fixedSize(horizontal: false, vertical: true)
    /// 允许宽度任意压缩 + LazyVGrid adaptive 塌缩 → 单字宽逐字竖排。
    /// 修复形态 = lineLimit(1) + chip 整体 .fixedSize()（与 SearchScreen
    /// 已验证形态一致）。守卫两者：竖排形态必须消失、横排形态必须在。
    func testHistoryChipsHorizontalLayoutGuard() {
        let src = Self.codeOnly("TingYou/UI/Discover/DiscoverScreen.swift")
        XCTAssertFalse(src.contains("fixedSize(horizontal: false, vertical: true)"),
                       "竖排根因形态必须消失（b44 回归：宽度塌缩成单字宽逐字换行）")
        XCTAssertTrue(src.contains(".lineLimit(1)"), "历史词条必须 lineLimit(1) 单行截断")
        XCTAssertTrue(src.contains(".fixedSize()"), "chip 整体必须 .fixedSize()（按内容自适应宽度，不塌缩）")
    }

    // MARK: - 反馈 3 · 悦听全链摘除

    /// 摘除守卫：Ytysxs* 源文件必须不存在；主 target 不得残留任何
    /// Ytysxs 类型/类名引用（小写 "ytysxs" 字符串仅允许出现在存量书
    /// 兼容层：describePlaybackError 提示文案 + ShelfScreen kindLabel）。
    func testYtysxsFullyRemovedGuard() throws {
        let fm = FileManager.default
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        for gone in ["TingYou/Services/YtysxsAdapter.swift",
                     "TingYou/UI/Components/YtysxsVerifyWebView.swift",
                     "TingYou/UI/Components/YtysxsVerifySheetState.swift",
                     "TingYou/Services/KeychainTokenStore.swift",
                     "TingYouTests/YtysxsAdapterTests.swift",
                     "TingYouTests/YtysxsCookieMatchingTests.swift",
                     "TingYouTests/YtysxsVerifySheetStateTests.swift",
                     "TingYouTests/KeychainTokenStoreTests.swift"] {
            XCTAssertFalse(fm.fileExists(atPath: projectDir + "/" + gone),
                           "\(gone) 必须已删除（悦听全链摘除）")
        }
        // 主 target：Ytysxs 类名 / AntibotException / antibotKeyword 零残留
        let enumFiles = try fm.contentsOfDirectory(atPath: projectDir + "/TingYou")
        for dir in enumFiles where dir.hasSuffix(".swift") {
            let raw = try String(contentsOfFile: projectDir + "/TingYou/" + dir, encoding: .utf8)
            // 代码级判定（剔除整行注释）：注释里的「已删除」说明不算残留引用
            let code = raw.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertFalse(code.contains("Ytysxs"), "\(dir) 不得残留 Ytysxs 类型引用（注释说明除外）")
            XCTAssertFalse(code.contains("AntibotException"), "\(dir) 不得残留 AntibotException")
        }
    }

    /// 存量书兼容：悦听来源的书点击播放必须给出人话失效提示（不删用户数据）。
    func testLegacyYtysxsPlaybackErrorMessageGuard() {
        let pm = Self.loadSource("TingYou/Playback/PlaybackManager.swift")
        XCTAssertTrue(pm.contains(#"source == "ytysxs""#), "describePlaybackError 必须识别存量悦听书")
        XCTAssertTrue(pm.contains("悦听有声书源已下线"), "存量悦听书必须给人话失效提示（换源收听）")
        let shelf = Self.loadSource("TingYou/UI/Shelf/ShelfScreen.swift")
        XCTAssertTrue(shelf.contains("悦听（已下线）"), "书架悦听来源必须标注已下线（不删数据）")
    }
}
