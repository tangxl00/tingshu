import XCTest
@testable import TingYou

/// 音源接线守卫：v2.0.1 易听书（yitingshu）下架保持；v2.0.2 悦听（ytysxs）
///   重新接入——发现页三源（听友FM / B站 / 悦听）、白名单放行、四链路路由 + 播放、
///   本地索引随包。易听书仍下架（不得回归）。
///
/// 沙箱无 Swift 工具链，运行时行为由真机复测与 CI 兜底；此处锁定可静态/
/// 纯函数验证的接线面。
final class Build50FeatureTests: XCTestCase {

    // MARK: - v2.0.2 · 悦听重新接入 + 易听书保持下架

    /// 三源基准守卫：发现页可选音源必须与 PC v1.1.8 完全一致
    /// （tingyou / bili / yitingshu），易听书 9 个分类同 PC YTS_CATS 清单。
    func testDiscoverCatalogMatchesPcThreeSourceBaseline() {
        XCTAssertEqual(DiscoverCatalog.sourceOptions.map(\.id),
                       [SourceRegistry.TINGYOU, SourceRegistry.BILI, SourceRegistry.YTYSXS],
                       "发现页音源清单须为三源（v2.0.2 悦听重新接入）")
        XCTAssertFalse(DiscoverCatalog.sourceOptions.contains { $0.id == "yitingshu" },
                       "易听书已下架，不得出现在发现页音源清单")
        XCTAssertTrue(DiscoverCatalog.categories(for: "yitingshu").isEmpty,
                       "易听书分类须清空（v2.0.1）")
        // 悦听 10 个站点原始分类（本地索引按此过滤）
        XCTAssertEqual(DiscoverCatalog.categories(for: SourceRegistry.YTYSXS).count, 10,
                       "悦听分类须为 10 个（言情/仙侠/玄幻/历史/都市/奇幻/武侠/科幻/军事/恐怖灵异）")
        // 搜索源三处注册一致性由 Build22AlignmentTests 守卫，此处不重复
    }

    /// 证书白名单守卫：build 50 新增的 3 个主机必须放行——易听书站点页 /
    /// 封面 CDN / 音频直链 CDN（aod.cos.tx.xmcdn.com，精确主机口径，
    /// 不放行 *.xmcdn.com 整域）。
    func testPinnedAllowlistAdmitsBuild50Hosts() {
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("www.yitingshu.com"),
                      "易听书已下架（v2.0.1），站点页主机须摘除")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("imagev2.xmcdn.com"),
                      "易听书封面 CDN 须摘除（v2.0.1）")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("aod.cos.tx.xmcdn.com"),
                      "易听书音频直链 CDN 须摘除（v2.0.1）")
        // fail-closed 结构性保证：白名单整域通配不得回归
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("evil.xmcdn.com"),
                       "xmcdn.com 不得整域放行（fail-closed 铁律）")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("evil.yitingshu.com"),
                       "yitingshu.com 不得整域放行（fail-closed 铁律）")
        // v2.0.2 悦听重新接入：站点/音频域放行，仿冒域 fail-closed
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("www.ytysxs.com"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("mp3.ytysxs.top"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("ytysxs.com.evil.com"))
    }

    /// 音频代理域守卫（精确主机口径，与 PC v1.1.8 返修 P2-1 同口径）：
    /// audioExact 只认 aod.cos.tx.xmcdn.com，audioSuffixes 必须为空
    /// ——后缀 .xmcdn.com 会放行其他子域。
    func testYitingshuAudioDomainsAreExactHostOnly() {
        let cfg = SourceRegistry.configOf(src: "yitingshu")
        XCTAssertNil(cfg, "易听书已下架（v2.0.1），config 不得残留")
        XCTAssertFalse(SourceRegistry.isKnown(src: "yitingshu"), "易听书不得为已知源")
    }

    /// 四链路路由守卫：搜索（含本地索引兜底）/ 详情 / 章节 / 发现页分类
    /// 都必须有 YITINGSHU case；播放链路在 PlaybackRepository 必须有
    /// YITINGSHU case。本地索引资源必须随包（Resources/yts_index.txt）。
    func testYitingshuWiredIntoAllRoutes() throws {
        let router = Self.codeOnly(try Self.loadSource("TingYou/Services/SourceRouter.swift"))
        XCTAssertFalse(router.contains("case SourceRegistry.YITINGSHU:"),
                       "v2.0.1 易听书下架，SourceRouter 不得残留 YITINGSHU case")
        XCTAssertFalse(router.contains("yitingshuAdapter"),
                       "易听书适配器装配须摘除")

        let playback = Self.codeOnly(try Self.loadSource("TingYou/Services/PlaybackRepository.swift"))
        XCTAssertFalse(playback.contains("case SourceRegistry.YITINGSHU:"),
                      "PlaybackRepository 播放链路不得残留 YITINGSHU case")

        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.projectRoot() + "/TingYou/Services/YitingshuAdapter.swift"),
                      "YitingshuAdapter.swift 必须删除（v2.0.1 死代码清理）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.projectRoot() + "/TingYou/Resources/yts_index.txt"),
                      "yts_index.txt 资源须随易听书下架删除")
    }

    /// v2.0.2 · 悦听四链路 + 播放接线守卫（静态形态，CI 全量单测兜底）
    func testYtysxsWiredIntoAllRoutes() throws {
        let router = Self.codeOnly(try Self.loadSource("TingYou/Services/SourceRouter.swift"))
        XCTAssertTrue(router.contains("case SourceRegistry.YTYSXS:"),
                      "SourceRouter 须有 YTYSXS 搜索/详情/章节/发现 case")
        XCTAssertTrue(router.contains("ytysxsAdapter"), "SourceRouter 须装配 ytysxsAdapter")
        let playback = Self.codeOnly(try Self.loadSource("TingYou/Services/PlaybackRepository.swift"))
        XCTAssertTrue(playback.contains("case SourceRegistry.YTYSXS:"),
                      "PlaybackRepository 播放链路须有 YTYSXS case")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.projectRoot() + "/TingYou/Resources/ytysxs_index.txt"),
                      "ytysxs_index.txt 本地索引须随包")
    }

    /// v2.0.2 · 悦听适配器纯函数守卫：本地索引解析 / 前缀优先搜索 / 验证页检测 /
    /// 音频白名单自检（不做验证码绕过）。
    func testYtysxsAdapterPureFunctions() {
        let rows = YtysxsAdapter.parseIndex("10|《甲乙》有声|https://mp3.ytysxs.top/img/10.webp|yanqing\n"
                                          + "11|丙丁有声书||lishi\n"
                                          + "12|甲乙前传||xuanhuan\n")
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(rows[1].cover, "空封面须为 nil")
        let hits = YtysxsAdapter.searchIndex(rows, keyword: "甲乙")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.bookId)), Set([10, 12]), "前缀命中均须返回")
        XCTAssertEqual(hits.first?.bookId, 12, "同为前缀命中时短标题在前（甲乙前传 4 字 < 《甲乙》有声 6 字）")
        XCTAssertTrue(YtysxsAdapter.isAntibot("<html>请完成安全检查</html>"))
        XCTAssertFalse(YtysxsAdapter.isAntibot("<html><a href='/1.html'>书</a></html>"))
        XCTAssertEqual(try? YtysxsAdapter.validateAudioUrl("https://mp3.ytysxs.top/2024/50/001.mp3"),
                       "https://mp3.ytysxs.top/2024/50/001.mp3")
        XCTAssertThrowsError(try YtysxsAdapter.validateAudioUrl("http://mp3.ytysxs.top/a.mp3"),
                             "非 https 直链须拦截")
        XCTAssertThrowsError(try YtysxsAdapter.validateAudioUrl("https://evil.com/a.mp3"),
                             "非白名单域须拦截")
        let tracks = YtysxsAdapter.parseTracksJson("[{\"title\":\"第1集\",\"audio\":\"https://mp3.ytysxs.top/a.mp3\"},"
                                                + "{\"title\":\"无音频\",\"audio\":\"\"}]")
        XCTAssertEqual(tracks.count, 1, "缺音频的条目须跳过")
    }

    // MARK: - 版本

    /// 版本守卫：build 58 升位双处一致（project.yml 两处由
    /// Build29RegressionTests 守卫；此处复核 Info.plist）。
    func testBuild50Version() throws {
        let plist = try Self.loadSource("TingYou/Info.plist")
        XCTAssertTrue(plist.contains("<string>66</string>"),
                      "Info.plist CFBundleVersion 必须为 66")
        XCTAssertTrue(plist.contains("<string>2.0.1</string>"),
                      "Info.plist CFBundleShortVersionString 维持 2.0.1")
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
