import XCTest
import SwiftUI
@testable import TingYou

// MARK: - build 22 · P1 修复：倍速选择写入 Binding（修复前只回调不写 speed）

final class SpeedSheetBindingTests: XCTestCase {

    func testSelectWritesSpeedBindingAndFiresCallback() {
        var current: Float = 1.0
        var callbackValue: Float?
        let sheet = SpeedSheet(
            speed: Binding(get: { current }, set: { current = $0 }),
            onSelect: { callbackValue = $0 })
        sheet.select(2.0)
        // 修复前：speed Binding 的 set 从不被触发（onSelect 被调用但调用点传空闭包）——倍速点了没反应
        XCTAssertEqual(current, 2.0, "select 必须写入 speed Binding")
        XCTAssertEqual(callbackValue, 2.0, "onSelect 回调照常触发（双保险）")
    }

    func testSelectTracksLatestChoice() {
        var current: Float = 1.0
        let sheet = SpeedSheet(
            speed: Binding(get: { current }, set: { current = $0 }),
            onSelect: { _ in })
        sheet.select(1.5)
        sheet.select(0.75)
        XCTAssertEqual(current, 0.75, "连续选择以最后一次为准")
    }
}

// MARK: - build 22 · 对齐安卓：聚合搜索按启用集过滤

/// 假搜索路由：按源返回固定结果 / 抛指定错误，并记录被搜索的源（验证启用集过滤）。
private final class FakeSearcher: SourceSearching, @unchecked Sendable {
    var results: [String: [Album]] = [:]
    var failures: [String: Error] = [:]
    /// build 24：每源延迟（并行化测试用；并行下 searchedSources 完成顺序不定）
    var delayNanos: UInt64 = 0
    private let lock = NSLock()
    private(set) var searchedSources: [String] = []

    func search(src: String, keyword: String) async throws -> [Album] {
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        lock.lock()
        defer { lock.unlock() }
        searchedSources.append(src)
        if let error = failures[src] { throw error }
        return results[src] ?? []
    }

    /// build 35（测试编译修复）：searchedSources 为 private(set)，
    /// 测试方法外部 removeAll() 是 setter 访问被拒（CI test.log build 34）；
    /// 以同一锁保护的复位方法保留「二次搜索前清空」语义。
    func resetSearchLog() {
        lock.lock()
        defer { lock.unlock() }
        searchedSources.removeAll()
    }
}

final class AggregateSearchTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "agg-search-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> SourceEnabledStore {
        SourceEnabledStore(defaults: defaults)
    }

    private func album(_ id: Int64, _ title: String, src: String) -> Album {
        Album(albumId: id, title: title, author: nil, teller: nil, coverUrl: nil, intro: nil,
              category: nil, categoryId: nil, type: nil, typeId: nil, status: nil,
              chapterCount: nil, updatedAt: nil, playCount: nil, available: true,
              source: src, detailPath: "/\(id)")
    }

    /// 聚合只搜启用源（关一个源少一个源的结果），且顺序 = searchSources 固定序。
    /// build 36：听吧下架（7→6 源）后按 6 源现实重写断言（原 5 源假设已过时）。
    func testAggregatesOnlyEnabledSourcesInFixedOrder() async {
        let store = makeStore()
        store.setEnabled(SourceRegistry.MEKUI, false) // 关书音FM
        store.setEnabled(SourceRegistry.BILI, false) // 关B站

        let searcher = FakeSearcher()
        searcher.results = [
            SourceRegistry.TINGYOU: [album(1, "听友书", src: SourceRegistry.TINGYOU)],
            SourceRegistry.TING15: [album(2, "听十五书", src: SourceRegistry.TING15)],
            SourceRegistry.MEKUI: [album(4, "书音书", src: SourceRegistry.MEKUI)],
        ]

        let outcome = await AggregateSearcher(searcher: searcher, enabledStore: store)
            .search(keyword: "书")

        XCTAssertEqual(Set(searcher.searchedSources), Set([SourceRegistry.TINGYOU, SourceRegistry.TING15, SourceRegistry.YTYXSX, SourceRegistry.TING59]),
                       "关闭的源（mekui/bili）不参与搜索；build 24 并行化后完成顺序不定，参与集合仍 = 启用集")
        XCTAssertEqual(searcher.searchedSources.count, 4, "每个启用源恰好搜索一次")
        XCTAssertEqual(outcome.searchedSources, [SourceRegistry.TINGYOU, SourceRegistry.TING15, SourceRegistry.YTYXSX, SourceRegistry.TING59],
                       "outcome.searchedSources 仍为固定序（结果组装以固定序进行）")
        XCTAssertEqual(outcome.albums.map(\.title), ["听友书", "听十五书"],
                       "关闭源的结果不出现")
        XCTAssertTrue(outcome.failedSourceNames.isEmpty)
        XCTAssertFalse(outcome.allFailed)
    }

    /// build 24（P2-2 · 性能）：并行化后结果仍按固定序拼接，且最坏耗时 ≈ 最慢单源
    /// 而非逐源求和。各源各延迟 0.2s（6 源串行和 = 1.2s，并行预期 ≈ 0.2s + 调度开销），
    /// 断言总耗时 < 0.55s（给 CI 调度抖动留 2 倍最慢单源余量）。
    /// build 36：听吧下架（7→6 源）后按 6 源现实重写（原 5 源假设已过时）。
    func testParallelSearchKeepsFixedOrderAndOverlapsInTime() async {
        let store = makeStore() // 默认全启用
        let searcher = FakeSearcher()
        searcher.delayNanos = 200_000_000
        searcher.results = [
            SourceRegistry.TINGYOU: [album(1, "听友书", src: SourceRegistry.TINGYOU)],
            SourceRegistry.TING15: [album(2, "听十五书", src: SourceRegistry.TING15)],
            SourceRegistry.YTYXSX: [album(4, "悦听书", src: SourceRegistry.YTYXSX)],
            SourceRegistry.MEKUI: [album(5, "书音书", src: SourceRegistry.MEKUI)],
        ]

        let start = Date()
        let outcome = await AggregateSearcher(searcher: searcher, enabledStore: store)
            .search(keyword: "书")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome.albums.map(\.title), ["听友书", "听十五书", "悦听书", "书音书"],
                       "并行化后结果仍按 searchSources 固定序拼接")
        XCTAssertEqual(outcome.searchedSources, SourceEnabledStore.searchSources)
        XCTAssertLessThan(elapsed, 0.55,
                          "并行总耗时应 ≈ 最慢单源（0.2s）而非串行求和（1.2s）；实测 \(elapsed)s")
    }

    /// 关一个源后，该源的结果从聚合中消失（启用开关真正控制搜索范围）。
    func testDisablingSourceRemovesItsResults() async {
        let store = makeStore()
        let searcher = FakeSearcher()
        searcher.results = [
            SourceRegistry.TINGYOU: [album(1, "a", src: SourceRegistry.TINGYOU)],
            SourceRegistry.TING15: [album(2, "b", src: SourceRegistry.TING15)],
        ]

        let before = await AggregateSearcher(searcher: searcher, enabledStore: store).search(keyword: "k")
        XCTAssertEqual(before.albums.count, 2)

        store.setEnabled(SourceRegistry.TING15, false)
        searcher.resetSearchLog()
        let after = await AggregateSearcher(searcher: searcher, enabledStore: store).search(keyword: "k")
        XCTAssertEqual(after.albums.count, 1, "关听十五后其结果消失")
        XCTAssertEqual(after.albums.first?.title, "a")
    }

    /// 单源失败不拖垮整体：失败源名如实透出。
    func testFailedSourceSurfacedNotFatal() async {
        let store = makeStore()
        let searcher = FakeSearcher()
        searcher.results = [SourceRegistry.TINGYOU: [album(1, "听友书", src: SourceRegistry.TINGYOU)]]
        searcher.failures[SourceRegistry.MEKUI] = URLError(.badServerResponse)

        let outcome = await AggregateSearcher(searcher: searcher, enabledStore: store)
            .search(keyword: "书")

        XCTAssertEqual(outcome.albums.map(\.title), ["听友书"], "单源失败不影响其余源聚合")
        XCTAssertEqual(outcome.failedSourceNames, ["书音FM"], "失败源显示名如实透出")
        XCTAssertFalse(outcome.allFailed, "部分成功不算整体失败")
    }

    /// 悦听反爬拦截：关键词回传（UI 弹 YtysxsVerifySheet 用）。
    func testAntibotKeywordPropagated() async {
        let store = makeStore()
        let searcher = FakeSearcher()
        searcher.results = [SourceRegistry.TINGYOU: [album(1, "听友书", src: SourceRegistry.TINGYOU)]]
        searcher.failures[SourceRegistry.YTYXSX] = AntibotException(keyword: "三体")

        let outcome = await AggregateSearcher(searcher: searcher, enabledStore: store)
            .search(keyword: "三")

        XCTAssertEqual(outcome.antibotKeyword, "三体", "AntibotException 关键词透传")
        XCTAssertFalse(outcome.allFailed, "反爬源不计入整体失败")
    }

    /// build 36 · 反馈 1：59听书站点级验证拦截计入失败源名并附明确标注，
    /// 不静默吞为 0 结果；且不得误触发悦听验证闭环（antibotKeyword 保持 nil）。
    func testTing59AntibotSurfacedWithAnnotation() async {
        let store = makeStore()
        let searcher = FakeSearcher()
        searcher.results = [SourceRegistry.TINGYOU: [album(1, "听友书", src: SourceRegistry.TINGYOU)]]
        searcher.failures[SourceRegistry.TING59] = Ting59AntibotException()

        let outcome = await AggregateSearcher(searcher: searcher, enabledStore: store)
            .search(keyword: "书")

        XCTAssertEqual(outcome.albums.map(\.title), ["听友书"], "59 拦截不影响其余源聚合")
        XCTAssertEqual(outcome.failedSourceNames, ["59听书网（需安全验证）"],
                       "59 验证拦截附明确标注透出")
        XCTAssertNil(outcome.antibotKeyword, "59 验证拦截不得误触发悦听验证闭环")
        XCTAssertFalse(outcome.allFailed)
    }

    /// 全部参与源失败才 allFailed（对齐安卓 anySuccess 语义）。
    /// build 36：听吧下架（7→6 源）后按 6 源现实重写——关 5 个只剩 tingyou。
    func testAllFailedOnlyWhenEverySourceFailed() async {
        let store = makeStore()
        store.setEnabled(SourceRegistry.TING15, false)
        store.setEnabled(SourceRegistry.YTYXSX, false)
        store.setEnabled(SourceRegistry.MEKUI, false)
        store.setEnabled(SourceRegistry.BILI, false)
        store.setEnabled(SourceRegistry.TING59, false) // 只剩 tingyou
        let searcher = FakeSearcher()
        searcher.failures[SourceRegistry.TINGYOU] = URLError(.timedOut)

        let outcome = await AggregateSearcher(searcher: searcher, enabledStore: store)
            .search(keyword: "k")
        XCTAssertTrue(outcome.allFailed, "唯一参与的源失败 → allFailed")
        XCTAssertEqual(outcome.failedSourceNames, ["听友FM"])
    }

    /// searchSources 固定清单：build 36 删听吧后 6 源、不含导入。
    func testSearchSourcesFixedOrderExcludesImport() {
        XCTAssertEqual(SourceEnabledStore.searchSources, [
            SourceRegistry.TINGYOU, SourceRegistry.TING15,
            SourceRegistry.YTYXSX, SourceRegistry.MEKUI,
            SourceRegistry.BILI, SourceRegistry.TING59,
        ])
        XCTAssertFalse(SourceEnabledStore.searchSources.contains(SourceRegistry.IMPORT),
                       "导入不参与搜索聚合")
    }
}

// MARK: - build 22 · 对齐安卓：至少保留一个启用源

final class SourceEnabledStoreGuardTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: SourceEnabledStore!

    override func setUp() {
        super.setUp()
        suiteName = "src-guard-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SourceEnabledStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    /// 关到只剩一个搜索源后，关闭最后一个被拒绝（状态不变）。
    func testLastEnabledSourceCannotBeDisabled() {
        // 全新 suite：默认全开。build 36（6 源）依次关 5 个（每次仍有其他启用源 → 允许）
        XCTAssertTrue(store.setEnabledGuarded(SourceRegistry.TING15, false))
        XCTAssertTrue(store.setEnabledGuarded(SourceRegistry.YTYXSX, false))
        XCTAssertTrue(store.setEnabledGuarded(SourceRegistry.MEKUI, false))
        XCTAssertTrue(store.setEnabledGuarded(SourceRegistry.BILI, false))
        XCTAssertTrue(store.setEnabledGuarded(SourceRegistry.TING59, false))
        XCTAssertEqual(store.enabledSearchSources(), [SourceRegistry.TINGYOU])

        // 关最后一个：拒绝
        XCTAssertFalse(store.setEnabledGuarded(SourceRegistry.TINGYOU, false),
                       "关闭最后一个启用的搜索源必须被拒绝")
        XCTAssertTrue(store.isEnabled(SourceRegistry.TINGYOU), "拒绝后状态不变（仍启用）")
    }

    /// 拒绝后重新打开其他源、再关上一个源：允许（保护只针对「最后一个」）。
    func testClosingPreviousSourceAllowedAfterReEnable() {
        store.setEnabledGuarded(SourceRegistry.TING15, false)
        store.setEnabledGuarded(SourceRegistry.YTYXSX, false)
        store.setEnabledGuarded(SourceRegistry.MEKUI, false)
        store.setEnabledGuarded(SourceRegistry.BILI, false)
        store.setEnabledGuarded(SourceRegistry.TING59, false)
        XCTAssertFalse(store.setEnabledGuarded(SourceRegistry.TINGYOU, false)) // 最后一个，拒绝

        XCTAssertTrue(store.setEnabledGuarded(SourceRegistry.TING15, true), "重新启用听十五允许")
        XCTAssertTrue(store.setEnabledGuarded(SourceRegistry.TINGYOU, false), "有了其他启用源后，关闭听友允许")
        XCTAssertEqual(store.enabledSearchSources(), [SourceRegistry.TING15])
    }

    /// 导入源不受「至少一个」保护（不参与搜索聚合，可自由开关）。
    func testImportToggleNotGuarded() {
        store.setEnabledGuarded(SourceRegistry.TING15, false)
        store.setEnabledGuarded(SourceRegistry.YTYXSX, false)
        store.setEnabledGuarded(SourceRegistry.MEKUI, false)
        store.setEnabledGuarded(SourceRegistry.BILI, false)
        store.setEnabledGuarded(SourceRegistry.TING59, false)
        // 只剩 tingyou 一个搜索源时，导入仍可自由关闭
        XCTAssertTrue(store.setEnabledGuarded(SourceRegistry.IMPORT, false),
                     "导入不受最后源保护")
        XCTAssertFalse(store.isEnabled(SourceRegistry.IMPORT))
        // 且导入的开关状态不影响 enabledSearchSources
        XCTAssertEqual(store.enabledSearchSources(), [SourceRegistry.TINGYOU])
    }

    /// toggleSource 翻转语义与定向守卫一致。
    func testToggleSourceFlips() {
        XCTAssertTrue(store.isEnabled(SourceRegistry.TING15))
        XCTAssertTrue(store.toggleSource(SourceRegistry.TING15))
        XCTAssertFalse(store.isEnabled(SourceRegistry.TING15))
        XCTAssertTrue(store.toggleSource(SourceRegistry.TING15))
        XCTAssertTrue(store.isEnabled(SourceRegistry.TING15))
    }
}
