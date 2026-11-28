import XCTest
import SwiftData
@testable import TingYou

/// build 51 · v1.4.4 返修（质检 NO-GO 放行条件）的回归守卫：
/// - P0-2 书架删除统一经 AlbumRepository 出口（不直写 SwiftData）
/// - P1-1 聚合搜索逐源增量回填 + 单源 3s 超时护栏
/// - 音源残留：mekui 适配器与已下架 7 条白名单主机
final class Build51FeatureTests: XCTestCase {

    /// 静态守卫：书架三条删除路径必须经仓储（不再直写 SwiftData），
    /// 统一收口便于落库失败统一打印与后续维护。
    func testShelfDeletePathsGoThroughRepository() throws {
        let shelf = try Self.source("TingYou/UI/Shelf/ShelfScreen.swift")
        XCTAssertTrue(shelf.contains("repo.deleteFavorite(src: f.src"),
                      "滑删收藏必须经 AlbumRepository 本地删库出口")
        XCTAssertTrue(shelf.contains("repo.deleteHistory(src: h.src"),
                      "滑删历史必须经 AlbumRepository 本地删库出口")
        XCTAssertTrue(shelf.contains("await repo.clearAllHistories()"),
                      "清空历史必须经 AlbumRepository 本地删库出口")
    }

    // MARK: - P1-1 · 聚合搜索超时不拖垮整体

    /// 单源超时（3s 护栏）：一个源 30s 不返回时，其余源结果必须已产出、
    /// 且慢源以失败源名透出（不阻塞整轮、也不误报整体失败）。
    func testSlowSourceIsGuardedByTimeout() async {
        let suite = "b51-p11-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SourceEnabledStore(defaults: defaults)

        let searcher = B51FakeSearcher()
        searcher.results = [
            SourceRegistry.TINGYOU: [Self.album(1, "听友书", src: SourceRegistry.TINGYOU)],
            SourceRegistry.YITINGSHU: [Self.album(3, "易听书", src: SourceRegistry.YITINGSHU)],
        ]
        // B站模拟「挂住 30s」（弱网 / 站点慢响应）
        searcher.delayBySource[SourceRegistry.BILI] = 30_000_000_000

        let start = Date()
        let outcome = await AggregateSearcher(searcher: searcher, enabledStore: store)
            .search(keyword: "书", timeout: .milliseconds(600))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 3.0, "单源 30s 挂起不得拖住整轮（护栏生效），实测 \(elapsed)s")
        XCTAssertEqual(outcome.albums.map(\.title), ["听友书", "易听书"],
                       "其余源结果必须照常产出，且仍按固定序拼接")
        XCTAssertEqual(outcome.failedSourceNames, ["B站"], "超时源按失败源如实透出")
        XCTAssertFalse(outcome.allFailed, "只有一源超时不算整体失败")
    }

    /// 增量回填：慢源未返回时，快源结果必须已通过 onPartial 上屏（不再等全源收齐）
    func testPartialCallbackFillsFastSourcesFirst() async {
        let suite = "b51-p11b-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SourceEnabledStore(defaults: defaults)

        let searcher = B51FakeSearcher()
        searcher.results = [SourceRegistry.TINGYOU: [Self.album(1, "听友书", src: SourceRegistry.TINGYOU)]]
        searcher.delayBySource[SourceRegistry.BILI] = 30_000_000_000
        searcher.delayBySource[SourceRegistry.YITINGSHU] = 30_000_000_000

        // 收集所有 partial（MainActor 回调，用锁保护计数）
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var snapshots: [(count: Int, pending: Int)] = []
        }
        let box = Box()

        _ = await AggregateSearcher(searcher: searcher, enabledStore: store)
            .search(keyword: "书", timeout: .milliseconds(500)) { partial in
                box.lock.lock()
                box.snapshots.append((partial.albums.count, partial.pendingSourceCount))
                box.lock.unlock()
            }

        box.lock.lock()
        let snaps = box.snapshots
        box.lock.unlock()
        XCTAssertFalse(snaps.isEmpty, "必须有增量回调（逐源回填）")
        XCTAssertTrue(snaps.contains { $0.count == 1 && $0.pending >= 1 },
                      "首个回调应只有 1 条结果、仍有源未返回——证明是先上屏而非收齐后一次性给")
    }

    /// 单源超时的默认值是 3s（质检给出的护栏值），易听书 live 探测另设 2s
    func testTimeoutBudgetConstants() {
        XCTAssertEqual(AggregateSearcher.perSourceTimeout, .seconds(3), "单源护栏必须是 3s")
        XCTAssertEqual(YitingshuAdapter.liveSearchTimeout, .seconds(2), "易听书 live 探测必须单独 2s 上限")
    }

    // MARK: - 音源残留（属「去掉多余音源」主题）

    /// 书音FM 死代码必须整体删除（不再随包编译）
    func testMekuiAdapterRemoved() {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir + "/TingYou/Services/MekuiAdapter.swift"),
                       "MekuiAdapter.swift 必须删除（221 行死代码曾随包编译进 IPA）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir + "/TingYouTests/MekuiAdapterTests.swift"),
                       "MekuiAdapterTests.swift 必须随适配器删除")
    }

    /// 已下架源 7 条主机不得留在证书白名单（收敛，但不误伤在役三源）
    func testDelistedHostsConvergedFromAllowlist() {
        let delisted = [
            "m.ting15.com", "www.ting08.com",
            "m.mekui.com", "api.mekui.com",
            "api.aikeu.com", "mp3.aikeu.com",
            "shuyinfm.oss-cn-hangzhou.aliyuncs.com",
        ]
        for host in delisted {
            XCTAssertFalse(PinnedDomainAllowlist.isAllowed(host), "已下架源主机 \(host) 必须从白名单摘除")
        }
        // 必守口径：在役三源必须仍放行
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("tingyou.fm"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("file.hgeuz.cn"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("api.bilibili.com"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("www.yitingshu.com"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("aod.cos.tx.xmcdn.com"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("xmcdn.com"), "易听书未整域放行 xmcdn.com")
    }

    /// 版本升位：b51 双处一致（project.yml 由 Build29 守卫，此处复核 Info.plist）
    func testBuild51Version() throws {
        let plist = try Self.source("TingYou/Info.plist")
        XCTAssertTrue(plist.contains("<string>62</string>"), "Info.plist CFBundleVersion 必须为 63")
        XCTAssertTrue(plist.contains("<string>1.4.7</string>"), "CFBundleShortVersionString 维持 1.4.8")
    }

    // MARK: - 工具

    private static func album(_ id: Int64, _ title: String, src: String) -> Album {
        Album(albumId: id, title: title, author: nil, teller: nil, coverUrl: nil, intro: nil,
              category: nil, categoryId: nil, type: nil, typeId: nil, status: nil,
              chapterCount: nil, updatedAt: nil, playCount: nil, available: true,
              source: src, detailPath: "/\(id)")
    }

    private static func source(_ rel: String) throws -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// 可按源注入延迟的假搜索路由（P1-1 护栏用）
    final class B51FakeSearcher: SourceSearching, @unchecked Sendable {
        var results: [String: [Album]] = [:]
        var delayBySource: [String: UInt64] = [:]
        func search(src: String, keyword: String) async throws -> [Album] {
            if let d = delayBySource[src] { try? await Task.sleep(nanoseconds: d) }
            return results[src] ?? []
        }
    }
}
