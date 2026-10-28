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
        // build 46 · 反馈 1：真机 -11828/-12847 根因守卫——proxy 重定向后
        // URLSession 重建的请求不保证保留 Range 头 → CDN 回 200 全量 →
        // 数据与 dataRequest 期望偏移错位 → moov 解析失败被判「格式不支持」。
        // 修复形态：attach 时按 dataRequest 存 Range（taskRanges），
        // willPerformHTTPRedirection 重建时 setValue 回填。
        XCTAssertTrue(pm.contains("taskRanges"), "必须保存 taskIdentifier → Range 映射（重定向重建依据）")
        XCTAssertTrue(pm.contains("Self.rangeHeader(for: dr)"), "attach 时必须按 dataRequest 组装 Range 头（口径与 proxyMedia 一致）")
        XCTAssertTrue(pm.contains("rangeHeader(for: task)"), "重定向回调必须能按 task 取回原始 Range")
        XCTAssertTrue(pm.contains(#"req.setValue(range, forHTTPHeaderField: "Range")"#),
                      "willPerformHTTPRedirection 重建请求时必须回填 Range 头（-12847 根因修复）")
        // build 46 · 反馈 1 增强：loader 元信息——resolve 直链域名 + loader 收到
        // 的 HTTP 状态/Content-Type 入诊断（下次失败一层看出喂的是什么）。
        XCTAssertTrue(pm.contains("metaRecorder"), "proxy delegate 必须持 metaRecorder 闭包（HTTP 状态/类型/域名入口）")
        XCTAssertTrue(pm.contains("recordLoaderMeta"), "PlaybackManager 必须有 recordLoaderMeta 元信息槽")
        XCTAssertTrue(pm.contains("loaderMetaRecord"), "元信息槽字段必须在（与 failure 槽同生命周期清理）")
        XCTAssertTrue(pm.contains("直链域名"), "resolve 成功必须记「resolve · 直链域名」入诊断")
        XCTAssertTrue(pm.contains("HTTP \\(http.statusCode) \\(http.mimeType"),
                      "didReceive response 必须记「play · HTTP 状态 类型」入诊断")
        // build 47 · 反馈 1a：偏移对齐防御层——Range 重注入之外的第二层保险
        //（两层任一生效即可播）。即使 Range 头在重定向后丢失（CDN 回 200
        // 全量），respond 前按 dataRequest 期望偏移丢弃错位前缀。
        XCTAssertTrue(pm.contains("taskOffsets"), "必须有流内「下一字节」偏移记账（对齐依据）")
        XCTAssertTrue(pm.contains("static func contentRangeStart"), "必须有 Content-Range 起始偏移解析（206 的实际起点）")
        XCTAssertTrue(pm.contains("advanceStreamOffset"), "每块数据处理后必须推进流内偏移")
        XCTAssertTrue(pm.contains("noteAlignmentSkip"), "丢弃错位数据时必须记「偏移对齐」诊断（取证用）")
        XCTAssertTrue(pm.contains("偏移对齐"), "对齐诊断文案必须在（失败时随 [诊断] 透出）")
        XCTAssertTrue(pm.contains("dr.requestedOffset"),
                      "对齐必须以 dataRequest.requestedOffset 为期望偏移")
        // build 47 · 反馈 1d：codec 过滤——EC-3（Dolby）轨 AVFoundation 不认
        //（b46 交付的观察项转正式修复）。
        let bili = Self.loadSource("TingYou/Services/BiliAdapter.swift")
        XCTAssertTrue(bili.contains("hasPlayableCodec"), "extractPlayableUrl 必须过 codec 过滤")
        XCTAssertTrue(bili.contains(#"ec-3"#), "必须按 codecs 排除 EC-3（Dolby）轨")
        // build 47 补丁 · 真机 octet-stream 修复（组长派单，真机 206 证据）：
        // B站镜像节点对 DASH 音轨回 application/octet-stream，AVPlayer 的
        // contentInformationRequest 按不支持格式拒收 → -12847。改写逻辑本体
        // 在 BiliContentTypeRewriteTests 真实逻辑单测；此处守卫 delegate 接线。
        XCTAssertTrue(pm.contains("static func rewrittenBiliContentType"),
                      "必须有 Content-Type 改写纯函数（供单测直接校验）")
        XCTAssertTrue(pm.contains("PlaybackManager.rewrittenBiliContentType("),
                      "didReceive response 必须接线改写（octet-stream → mp4）")
        XCTAssertTrue(pm.contains("Content-Type 改写: \\(original) → \\(effective)"),
                      "改写前后类型必须都进 [诊断]（截图可见「octet-stream → audio/mp4 已改写」）")
        XCTAssertTrue(pm.contains("if let mime = effectiveMime {"),
                      "contentInformationRequest 必须用改写后的类型（不得再喂 http.mimeType 原值）")
        XCTAssertTrue(pm.contains("static func sniffedBiliMp4Mime"),
                      "必须有 ftyp 嗅探兜底纯函数（无路径线索的 octet-stream 流）")
        XCTAssertTrue(pm.contains("PlaybackManager.sniffedBiliMp4Mime(data: data, streamOffset: streamOffset(for: dataTask))"),
                      "didReceive data 必须在偏移推进前按流内位置嗅探（编译修正：函数在 PlaybackManager 上，delegate 内调用需显式类型前缀）")
        XCTAssertTrue(pm.contains("taskSniffPending.remove(task.taskIdentifier)"),
                      "finish 必须清理嗅探挂起记账（防串任务）")
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
        // CI 第二轮（反馈 2）：mini 播放栏同口径锚——点集后 App 停在
        // 详情页 + MiniPlayerBar，判据只锚全屏按钮看不见 mini 播放态。
        let mini = Self.loadSource("TingYou/UI/Components/MiniPlayerBar.swift")
        XCTAssertTrue(mini.contains("mini_play_pause"), "mini 播放/暂停按钮必须有 identifier（XCUITest 锚）")
        XCTAssertTrue(mini.contains(#""暂停""#), "mini 播放/暂停按钮必须有「暂停」accessibilityLabel")
        // build 47 · H 用例稳定化：点章节前必须轮询等 album_chapter_row_0 真正
        // 出现（10s）——此前「查一次 exists 就回退」，四轮 CI 未跑成的共同
        // 根因是列表未渲染完成时点击落空。
        let hTest = Self.loadSource("TingYouUITests/BiliPlaybackUITests.swift")
        XCTAssertTrue(hTest.contains("firstCell.waitForExistence(timeout: 10)"),
                      "H 用例点章节前必须 10s 轮询等锚出现（不得查一次就回退点空）")
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
        // build 47 · 反馈 2（布局返修·用户可感知标准）：「发现」大标题改内联
        // 小标题——搜索框上移约一个标题行高度（~52pt）；历史区高度随内容
        // 自适应（≤8 条自然高度）——「一眼可见」标准的形态守卫。
        XCTAssertTrue(src.contains(".navigationBarTitleDisplayMode(.inline)"),
                      "「发现」大标题必须改内联小标题（大字标题多占 ~52pt 是顶部空白主源）")
        // build 48 · 需求 1：历史区全量换行显示——按条数分流与 160pt 限高
        // 两个截断形态必须消失（b47 形态回归即失配）。
        XCTAssertFalse(src.contains("history.count <= 8"),
                       "历史区不得再按条数分流（build 48 需求 1：全量换行显示）")
        XCTAssertFalse(src.contains("frame(height: 160)"),
                       "历史区不得再固定 160pt 限高（build 48 需求 1：全量换行显示）")
        XCTAssertFalse(src.contains("maxHeight:"),
                       "maxHeight 贪婪形态不得回归（内容再少也占满上限，撑出空白）")
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
    /// build 49 同步组长口径（远端 b48 守卫修正）：「悦听（已下线）」标注随
    /// b48 书架导入列表整体删除而消失——改为断言导入列表声明级类型不存在。
    func testLegacyYtysxsPlaybackErrorMessageGuard() {
        let pm = Self.loadSource("TingYou/Playback/PlaybackManager.swift")
        XCTAssertTrue(pm.contains(#"source == "ytysxs""#), "describePlaybackError 必须识别存量悦听书")
        XCTAssertTrue(pm.contains("悦听有声书源已下线"), "存量悦听书必须给人话失效提示（换源收听）")
        let shelf = Self.loadSource("TingYou/UI/Shelf/ShelfScreen.swift")
        // 否定断言用 `struct ` 声明级前缀——裸标识符会误中删除说明注释
        XCTAssertFalse(shelf.contains("struct ImportedBookRow"), "导入行视图声明必须已删除（随导入列表移除）")
        XCTAssertFalse(shelf.contains("struct ImportedBookGridItem"), "导入网格项声明必须已删除（随导入列表移除）")
    }
}
