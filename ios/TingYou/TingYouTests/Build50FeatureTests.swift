import XCTest
@testable import TingYou

/// build 50 · 音源对齐 PC（v1.1.8 三源基准）守卫：补齐易听书（yitingshu）——
///   注册/四链路路由/播放/发现页 9 分类/本地标题索引搜索/证书白名单。
///
/// 沙箱无 Swift 工具链，运行时行为由真机复测与 CI 兜底；此处锁定可静态/
/// 纯函数验证的接线面。
final class Build50FeatureTests: XCTestCase {

    // MARK: - 任务 2 · 易听书补齐（对齐 PC 三源基准）

    /// 三源基准守卫：发现页可选音源必须与 PC v1.1.8 完全一致
    /// （tingyou / bili / yitingshu），易听书 9 个分类同 PC YTS_CATS 清单。
    func testDiscoverCatalogMatchesPcThreeSourceBaseline() {
        XCTAssertEqual(DiscoverCatalog.sourceOptions.map(\.id),
                       [SourceRegistry.TINGYOU, SourceRegistry.BILI, SourceRegistry.YITINGSHU],
                       "发现页音源清单必须与 PC v1.1.8 三源基准一致（build 50 补齐易听书）")
        let yts = DiscoverCatalog.categories(for: SourceRegistry.YITINGSHU)
        XCTAssertEqual(yts.count, 9, "易听书分类必须为 9 个（PC YTS_CATS 同清单）")
        XCTAssertEqual(yts.first?.name, "言情", "易听书首个分类应为言情（PC 同顺序）")
        XCTAssertEqual(yts.last?.name, "商业财经", "易听书末个分类应为商业财经（PC 同顺序）")
        // 搜索源三处注册一致性由 Build22AlignmentTests 守卫，此处不重复
    }

    /// 证书白名单守卫：build 50 新增的 3 个主机必须放行——易听书站点页 /
    /// 封面 CDN / 音频直链 CDN（aod.cos.tx.xmcdn.com，精确主机口径，
    /// 不放行 *.xmcdn.com 整域）。
    func testPinnedAllowlistAdmitsBuild50Hosts() {
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("www.yitingshu.com"),
                      "易听书站点页主机必须放行（build 50）")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("imagev2.xmcdn.com"),
                      "易听书封面 CDN 必须放行（build 50）")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("aod.cos.tx.xmcdn.com"),
                      "易听书音频直链 CDN 必须放行（build 50）")
        // fail-closed 结构性保证：白名单整域通配不得回归
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("evil.xmcdn.com"),
                       "xmcdn.com 不得整域放行——只允许 imagev2 / aod.cos.tx 两个精确子域")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("evil.yitingshu.com"),
                       "yitingshu.com 不得整域放行（fail-closed 铁律）")
    }

    /// 音频代理域守卫（精确主机口径，与 PC v1.1.8 返修 P2-1 同口径）：
    /// audioExact 只认 aod.cos.tx.xmcdn.com，audioSuffixes 必须为空
    /// ——后缀 .xmcdn.com 会放行其他子域。
    func testYitingshuAudioDomainsAreExactHostOnly() {
        let cfg = SourceRegistry.configOf(src: SourceRegistry.YITINGSHU)
        XCTAssertNotNil(cfg, "易听书必须注册在 msrcSources（build 50）")
        XCTAssertEqual(cfg?.audioExact, ["aod.cos.tx.xmcdn.com"],
                       "音频直链只认精确主机 aod.cos.tx.xmcdn.com")
        XCTAssertEqual(cfg?.audioSuffixes ?? ["非空"], [],
                       "音频后缀白名单必须为空（不得整域放行 .xmcdn.com）")
        XCTAssertEqual(cfg?.fetchHosts, ["www.yitingshu.com"],
                       "站点页主机必须精确为 www.yitingshu.com")
    }

    /// 四链路路由守卫：搜索（含本地索引兜底）/ 详情 / 章节 / 发现页分类
    /// 都必须有 YITINGSHU case；播放链路在 PlaybackRepository 必须有
    /// YITINGSHU case。本地索引资源必须随包（Resources/yts_index.txt）。
    func testYitingshuWiredIntoAllRoutes() throws {
        let router = Self.codeOnly(try Self.loadSource("TingYou/Services/SourceRouter.swift"))
        let ytsCases = router.components(separatedBy: "case SourceRegistry.YITINGSHU:")
        XCTAssertEqual(ytsCases.count, 5,
                       "SourceRouter 必须有 4 个 YITINGSHU case（搜索/详情/章节/发现页分类），实际 \(ytsCases.count - 1) 个")
        XCTAssertTrue(router.contains("func discoverCategory(src: String, categoryId: String, page: Int)"),
                      "发现页分类路由必须存在（易听书走 /yi/{cat}-{page}.html 分类页口径）")

        let playback = Self.codeOnly(try Self.loadSource("TingYou/Services/PlaybackRepository.swift"))
        XCTAssertTrue(playback.contains("case SourceRegistry.YITINGSHU:"),
                      "PlaybackRepository 播放链路必须有 YITINGSHU case（var now 直链提取）")

        let adapter = Self.codeOnly(try Self.loadSource("TingYou/Services/YitingshuAdapter.swift"))
        XCTAssertTrue(adapter.contains("Bundle.main.url(forResource: \"yts_index\", withExtension: \"txt\")"),
                      "搜索必须加载本地标题索引 Resources/yts_index.txt（search.php 被 vdimgck 验证码拦截）")

        let project = try Self.loadSource("project.yml")
        XCTAssertTrue(project.contains("- path: TingYou/Resources"),
                      "Resources 目录必须整体入包（yts_index.txt 随包分发）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.projectRoot() + "/TingYou/Resources/yts_index.txt"),
                      "yts_index.txt 资源文件必须在场（16,671 条本地索引）")
    }

    // MARK: - 版本

    /// 版本守卫：build 58 升位双处一致（project.yml 两处由
    /// Build29RegressionTests 守卫；此处复核 Info.plist）。
    func testBuild50Version() throws {
        let plist = try Self.loadSource("TingYou/Info.plist")
        XCTAssertTrue(plist.contains("<string>59</string>"),
                      "Info.plist CFBundleVersion 必须为 59")
        XCTAssertTrue(plist.contains("<string>1.4.4</string>"),
                      "Info.plist CFBundleShortVersionString 维持 1.4.4")
    }

    // MARK: - 工具

    /// 读工程源码（相对工程根的路径），口径与 Build29RegressionTests 一致。
    private static func loadSource(_ rel: String) throws -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("\(rel) 不存在：\(path)——路径布局变化时请同步修正本测试")
            throw NSError(domain: "TestSourceMissing", code: 1)
        }
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(rel) 不可读：\(path)")
            throw NSError(domain: "TestSourceUnreadable", code: 2)
        }
        return src
    }

    private static func projectRoot() -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        return (testDir as NSString).deletingLastPathComponent
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
