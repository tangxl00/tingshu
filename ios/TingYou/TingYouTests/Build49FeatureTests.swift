import XCTest
@testable import TingYou

/// build 49 · 两项真机复测问题守卫。
///
/// 问题 1 · B站部分视频 TLS 错误未走镜像重试：真机《超清〈水-浒-传〉
///   全86集》upos-sz-mirrorcos TLS -1200 立即失败直接报终局错。修复 =
///   statusObserver .failed 分支按 NSURLErrorDomain 可重试码集分类，
///   与 watchdog 停滞共用 mirrorCandidates 链 / mirrorAttempts 计数，
///   链耗尽才报错并标注「已换镜像 N 次仍失败」；4xx/5xx（服务器拒绝，
///   含 412 风控）不进镜像重试。
/// 问题 2 · 历史搜索词条重叠：LazyVGrid adaptive 等宽列容不下 chip
///   .fixedSize() 固有宽度 → 相邻列横向叠压。修复 = Layout 协议
///   FlowLayout 逐 chip 累进放置（Discover + Search 两屏同修）。
///
/// 沙箱无 Swift 工具链，运行时行为（TLS 失败重放、真机布局渲染）由
/// 真机复测与 CI 兜底；此处锁定可静态验证的接线面与纯判定函数。
final class Build49FeatureTests: XCTestCase {

    // MARK: - 问题 1 · TLS/网络错误进镜像重试

    /// 问题 1 守卫（纯判定函数）：只有 NSURLErrorDomain 的网络层可重试
    /// 码集（TLS/证书 -1200..-1213、SecureTransport -9800..-9808、超时
    /// -1001、DNS -1003/-1006、连接失败 -1004/-1005、资源不可用 -1008）
    /// 才消耗镜像候选；取消（-999）、断网（-1009）、URL 畸形（-1000/-1002）、
    /// 服务器响应错误（-1011）与非 NSURLErrorDomain（AVFoundation 黑盒、
    /// HTTP 状态透传）一律不重试——4xx/5xx/412 不盲换镜像的结构性保证。
    func testMirrorRetryableNetworkErrorClassification() {
        func nsError(_ code: Int, domain: String = NSURLErrorDomain) -> NSError {
            NSError(domain: domain, code: code)
        }
        // 可重试族：TLS / 证书（真机 -1200 取证点）
        XCTAssertTrue(PlaybackManager.isMirrorRetryableNetworkError(nsError(-1200)),
                      "TLS 握手失败（-1200）必须可重试换镜像（真机取证点）")
        XCTAssertTrue(PlaybackManager.isMirrorRetryableNetworkError(nsError(-1213)),
                      "TLS/证书族上界 -1213 必须可重试")
        // 可重试族：SecureTransport 遗留 TLS（-9800..-9808）
        XCTAssertTrue(PlaybackManager.isMirrorRetryableNetworkError(nsError(-9803)),
                      "SecureTransport TLS 族（-980x）必须可重试")
        // 可重试族：连接层（超时 / DNS / 连接失败 / 重置 / 资源不可用）
        XCTAssertTrue(PlaybackManager.isMirrorRetryableNetworkError(nsError(-1001)),
                      "连接超时（-1001）必须可重试换镜像")
        XCTAssertTrue(PlaybackManager.isMirrorRetryableNetworkError(nsError(-1003)),
                      "DNS cannotFindHost（-1003）必须可重试")
        XCTAssertTrue(PlaybackManager.isMirrorRetryableNetworkError(nsError(-1005)),
                      "连接重置（-1005）必须可重试换镜像")
        XCTAssertTrue(PlaybackManager.isMirrorRetryableNetworkError(nsError(-1006)),
                      "DNS 解析失败（-1006）必须可重试")
        // 不可重试：取消（切章正常取消）/ 断网（换镜像无用）/ URL 畸形 /
        // 服务器响应错误（-1011，HTTP 层语义）
        XCTAssertFalse(PlaybackManager.isMirrorRetryableNetworkError(nsError(-999)),
                       "取消（-999）不得触发镜像重试（切章正常取消）")
        XCTAssertFalse(PlaybackManager.isMirrorRetryableNetworkError(nsError(-1009)),
                       "断网（-1009）不得触发镜像重试（换镜像无用）")
        XCTAssertFalse(PlaybackManager.isMirrorRetryableNetworkError(nsError(-1000)),
                       "URL 畸形（-1000）不得触发镜像重试")
        XCTAssertFalse(PlaybackManager.isMirrorRetryableNetworkError(nsError(-1002)),
                       "不支持的 URL（-1002）不得触发镜像重试")
        XCTAssertFalse(PlaybackManager.isMirrorRetryableNetworkError(nsError(-1011)),
                       "服务器响应错误（-1011）属 HTTP 层语义，不得按网络层盲换")
        // 不可重试：非 NSURLErrorDomain（AVFoundation 黑盒「Cannot Open」）
        XCTAssertFalse(PlaybackManager.isMirrorRetryableNetworkError(
            nsError(-11800, domain: "AVFoundationErrorDomain")),
                       "非 NSURLErrorDomain（AVFoundation 黑盒）不得触发镜像重试")
        XCTAssertFalse(PlaybackManager.isMirrorRetryableNetworkError(
            NSError(domain: "NSPOSIXErrorDomain", code: 28)),
                       "非 NSURLErrorDomain（POSIX）不得触发镜像重试")
    }

    /// 问题 1 守卫（接线面）：.failed 分支必须先走网络错误分类 → 有候选即
    /// 复用 b48 镜像切换机制（takeNextMirrorCandidate + storeResolved +
    /// keepMirrorChain 重建）→ 链耗尽才拼终局诊断；分类函数体内不得出现
    /// HTTP 状态 / 412 分支（4xx 不盲换的结构性保证）。
    func testTLSFailureWiredIntoMirrorRetryChain() {
        let pm = Self.codeOnly(Self.loadSource("TingYou/Playback/PlaybackManager.swift"))
        // 分类函数存在且只认 NSURLErrorDomain
        XCTAssertTrue(pm.contains("static func isMirrorRetryableNetworkError"),
                      "必须有网络错误分类纯函数（build 49 问题 1）")
        XCTAssertTrue(pm.contains("guard ns.domain == NSURLErrorDomain else { return false }"),
                      "分类函数必须只认 NSURLErrorDomain（其它 domain 一律不重试）")
        // .failed 分支接线：分类 → 当前条目守卫 → 候选出队 → 同机制切换
        XCTAssertTrue(pm.contains("Self.isMirrorRetryableNetworkError(error),"),
                      "statusObserver .failed 分支必须先过网络错误分类（build 49 问题 1）")
        XCTAssertTrue(pm.contains("item === self?.player.currentItem {"),
                      "只有当前条目的失败才触发镜像重试（切章拆旧条目的迟到 .failed 不重试）")
        XCTAssertTrue(pm.contains(#"self?.recordLoaderMeta("网络错误 \(ns.domain) \(ns.code) → 自动切换镜像第 \(attempts) 次 → \(host)")"#),
                      "网络错误切镜像必须落到诊断文案（build 49 问题 1）")
        XCTAssertTrue(pm.contains("storeResolved(key: uri, url: next)"),
                      "网络错误切镜像必须重定向占位 URI 缓存（与 watchdog 同机制）")
        XCTAssertTrue(pm.contains("loadCurrentChapter(autoPlay: true, keepMirrorChain: true)"),
                      "网络错误切镜像必须保留镜像链重建条目（与 watchdog 同机制）")
        // 链耗尽的终局诊断标注
        XCTAssertTrue(pm.contains(#"networkMirrorNote = attempts > 0"#),
                      "镜像链耗尽必须区分「已换 N 次仍失败」与「无可用镜像」两种文案")
        XCTAssertTrue(pm.contains(#"? "网络错误 → 已换镜像 \(attempts) 次仍失败""#),
                      "诊断必须标注已换镜像次数（TLS/网络错误 → 已换镜像 N 次仍失败）")
        XCTAssertTrue(pm.contains(": \"网络错误 → 无可用 backup 镜像\""),
                      "无 backup 镜像时诊断必须如实标注（不得谎报已换镜像）")
        XCTAssertTrue(pm.contains("diagnostic.append(networkMirrorNote)"),
                      "networkMirrorNote 必须拼进终局诊断 [诊断] 段")
        // 结构性保证：分类函数体内无 HTTP 状态 / 4xx / 412 分支
        let fnBody = Self.functionBody(of: pm, needle: "static func isMirrorRetryableNetworkError")
        XCTAssertFalse(fnBody.contains("412"), "分类函数不得按 412 风控换镜像（维持现行为）")
        XCTAssertFalse(fnBody.contains("statusCode"), "分类函数不得按 HTTP 状态码分支（4xx/5xx 不盲换）")
        XCTAssertFalse(fnBody.contains("http"), "分类函数不得出现 HTTP 层判定")
    }

    // MARK: - 问题 2 · 历史搜索词条重叠（FlowLayout）

    /// 问题 2 守卫：FlowLayout 存在且为 Layout 协议实现（逐 chip 累进放置、
    /// 折行由累进坐标决定——数学上不可能重叠）；Discover / Search 两屏
    /// 历史区都已替换，LazyVGrid adaptive 等宽列形态必须消失；chip 横排
    /// 形态（lineLimit(1) + 整体 .fixedSize()，b44 竖排回归防线）保留。
    func testHistoryChipsFlowLayoutNoOverlap() {
        let flow = Self.codeOnly(Self.loadSource("TingYou/UI/FlowLayout.swift"))
        let discover = Self.codeOnly(Self.loadSource("TingYou/UI/Discover/DiscoverScreen.swift"))
        let search = Self.codeOnly(Self.loadSource("TingYou/UI/Search/SearchScreen.swift"))
        // FlowLayout：Layout 协议 + 累进放置 + 折行判定
        XCTAssertTrue(flow.contains("struct FlowLayout: Layout"),
                      "必须实现 Layout 协议流式布局（build 49 问题 2）")
        XCTAssertTrue(flow.contains("func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ())"),
                      "FlowLayout 必须实现 sizeThatFits")
        XCTAssertTrue(flow.contains("func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ())"),
                      "FlowLayout 必须实现 placeSubviews")
        XCTAssertTrue(flow.contains("subview.sizeThatFits(.unspecified)"),
                      "FlowLayout 必须按子视图固有宽度提案（fixedSize chip 不被压缩）")
        XCTAssertTrue(flow.contains("if x > 0, x + size.width > maxWidth {"),
                      "折行必须由累进坐标判定（放不下才折行——排布无重叠的结构保证）")
        XCTAssertTrue(flow.contains("y += rowHeight + verticalSpacing"),
                      "行进必须按行高累进（行与行不叠压）")
        // Discover / Search 两屏接线（同款根因同款修复）
        XCTAssertTrue(discover.contains("FlowLayout(horizontalSpacing: 8, verticalSpacing: 6)"),
                      "发现页历史区必须用 FlowLayout（水平 8 / 垂直 6 对齐原列距行距）")
        XCTAssertTrue(search.contains("FlowLayout(horizontalSpacing: 8, verticalSpacing: 8)"),
                      "搜索页历史区必须用 FlowLayout（同款 LazyVGrid 叠压缺陷一并修复）")
        // 等宽列形态必须消失（叠压根因）
        XCTAssertFalse(discover.contains("GridItem(.adaptive(minimum: 44"),
                       "发现页不得残留 adaptive 等宽列形态（fixedSize chip 溢出叠压根因）")
        XCTAssertFalse(search.contains("GridItem(.adaptive(minimum: 44"),
                       "搜索页不得残留 adaptive 等宽列形态（同款叠压根因）")
        // chip 横排形态保留（b44 竖排回归防线，Build45FeedbackTests 同口径）
        XCTAssertTrue(discover.contains(".lineLimit(1)"), "发现页 chip 文字必须 lineLimit(1) 单行")
        XCTAssertTrue(search.contains(".lineLimit(1)"), "搜索页 chip 文字必须 lineLimit(1) 单行")
        XCTAssertTrue(discover.contains(".fixedSize()"), "发现页 chip 整体必须 .fixedSize()（不塌缩）")
        XCTAssertTrue(search.contains(".fixedSize()"), "搜索页 chip 整体必须 .fixedSize()（不塌缩）")
    }

    // MARK: - 版本

    /// build 49 版本守卫：Info.plist CFBundleVersion 必须为 49
    ///（project.yml 两处在 Build29RegressionTests 已守卫）。
    func testBuild49Version() {
        let plist = Self.loadSource("TingYou/Info.plist")
        XCTAssertTrue(plist.contains("<string>49</string>"),
                      "Info.plist CFBundleVersion 必须为 49")
        XCTAssertTrue(plist.contains("<string>1.4.4</string>"),
                      "Info.plist CFBundleShortVersionString 维持 1.4.4")
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

    /// 截取函数体：从 needle 所在行起、到下一个「static func」或「func」
    /// 声明行（不含）止——用于函数局部断言（防其它函数的同名标识符误判）。
    private static func functionBody(of code: String, needle: String) -> String {
        let lines = code.split(separator: "\n").map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(needle) }) else {
            return ""
        }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if (trimmed.hasPrefix("static func ") || trimmed.hasPrefix("func "))
                && !body.isEmpty {
                break
            }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }
}
