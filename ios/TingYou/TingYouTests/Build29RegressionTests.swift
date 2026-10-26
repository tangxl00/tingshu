import XCTest
@testable import TingYou

/// build 29 · 回归测试（R1-R8）。
/// 验证新增两源未破坏既有三源（ting15/ting08/ytysxs/mekui）行为与 v1.3.4 调整。
final class Build29RegressionTests: XCTestCase {

    // MARK: - R1-R4 · 聚合搜索源列表包含既有源（结构存在性，非网络测试）

    func testAggregateSearchSourcesIncludeLegacySources() {
        let sources = SourceEnabledStore.searchSources
        XCTAssertTrue(sources.contains(SourceRegistry.TINGYOU), "听友FM 必须在搜索源列表中")
        XCTAssertTrue(sources.contains(SourceRegistry.TING15), "听十五 必须在搜索源列表中")
        XCTAssertTrue(sources.contains(SourceRegistry.TING08), "听吧 必须在搜索源列表中")
        XCTAssertTrue(sources.contains(SourceRegistry.YTYXSX), "悦听有声书 必须在搜索源列表中")
        XCTAssertTrue(sources.contains(SourceRegistry.MEKUI), "书音FM 必须在搜索源列表中")
    }

    func testAggregateSearchSourcesIncludeNewSources() {
        let sources = SourceEnabledStore.searchSources
        XCTAssertTrue(sources.contains(SourceRegistry.BILI), "B站 必须在搜索源列表中")
        XCTAssertTrue(sources.contains(SourceRegistry.TING59), "59听书网 必须在搜索源列表中")
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
        XCTAssertEqual(SourceRegistry.displayName(src: "ting15"), "听十五")
        XCTAssertEqual(SourceRegistry.displayName(src: "ting08"), "听吧")
        XCTAssertEqual(SourceRegistry.displayName(src: "ytysxs"), "悦听有声书")
        XCTAssertEqual(SourceRegistry.displayName(src: "mekui"), "书音FM")
    }

    func testSourceRegistryNewSourcesRegistered() {
        XCTAssertEqual(SourceRegistry.displayName(src: "bili"), "B站")
        XCTAssertEqual(SourceRegistry.displayName(src: "ting59"), "59听书网")
        XCTAssertTrue(SourceRegistry.isKnown(src: "bili"))
        XCTAssertTrue(SourceRegistry.isKnown(src: "ting59"))
    }

    func testMsrcSourcesUnchanged() {
        XCTAssertNotNil(SourceRegistry.configOf(src: "ting15"))
        XCTAssertNotNil(SourceRegistry.configOf(src: "ting08"))
        XCTAssertNotNil(SourceRegistry.configOf(src: "mekui"))
        XCTAssertNil(SourceRegistry.configOf(src: "bili"), "B站不应进入 msrcSources")
        XCTAssertNil(SourceRegistry.configOf(src: "ting59"), "ting59 不应进入 msrcSources")
    }

    // MARK: - 版本号断言

    /// v1.4.2 · P2-2（质检）：原断言为 `XCTAssertTrue(true, …)` 恒真——不读文件不校验值，
    /// 版本号忘改也照常绿，防线形同虚设。重建为真读真比：经 `#filePath` 相对定位
    /// `ios/TingYou/project.yml`（测试文件在 TingYouTests/ 下，上溯两级即工程目录，
    /// 与 CI checkout 布局一致），逐行解析 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
    /// 首个定义并断言精确值。版本号忘改或格式漂移即测试红（CI 兜底）。
    /// v1.4.4：断言值随 build 34 同步升位（1.4.4 / 34）。
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
        XCTAssertEqual(Self.yamlFirstValue(of: "CURRENT_PROJECT_VERSION", in: yml), "34",
                       "project.yml CURRENT_PROJECT_VERSION 必须为 34（升版本时同步改此断言）")
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
            msrcAdapter: MsrcAdapter(apiClient: APIClient()),
            ytysxsAdapter: YtysxsAdapter(apiClient: APIClient()),
            mekuiAdapter: MekuiAdapter(apiClient: APIClient()),
            biliAdapter: BiliAdapter(),
            ting59Adapter: Ting59Adapter()
        )
    }
}
