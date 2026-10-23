import XCTest
@testable import TingYou

/// build 28：倍速/章节整行可点 + 收藏进度关联 + 搜索历史输入联动建议。
final class Build28Tests: XCTestCase {

    // MARK: - 搜索历史输入联动建议（SearchHistoryStore.matching）

    private func makeStore() -> SearchHistoryStore {
        let defaults = UserDefaults(suiteName: "Build28Tests-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "") }
        return SearchHistoryStore(defaults: defaults, key: "search_history_28")
    }

    /// 空 query 应返回全部历史（保持原顺序，队首最新）。
    func testMatchingEmptyQueryReturnsAll() {
        let store = makeStore()
        store.add("三国演义")
        store.add("水浒传")
        store.add("红楼梦")
        let all = store.all
        XCTAssertEqual(store.matching(""), all)
        XCTAssertEqual(store.matching("   "), all)
    }

    /// 前缀匹配：输入「三国」应命中「三国演义」。
    func testMatchingPrefix() {
        let store = makeStore()
        store.add("三国演义")
        store.add("水浒传")
        store.add("红楼梦")
        XCTAssertEqual(store.matching("三国"), ["三国演义"])
    }

    /// 包含匹配：输入「演义」应命中「三国演义」。
    func testMatchingContains() {
        let store = makeStore()
        store.add("三国演义")
        store.add("水浒传")
        XCTAssertEqual(store.matching("演义"), ["三国演义"])
    }

    /// 大小写不敏感：输入「hong」应命中「红楼梦」。
    func testMatchingCaseInsensitive() {
        let store = makeStore()
        store.add("红楼梦")
        store.add("水浒传")
        XCTAssertEqual(store.matching("hong"), ["红楼梦"])
        XCTAssertEqual(store.matching("HONG"), ["红楼梦"])
    }

    /// 多结果按原历史顺序返回（去重后保持队首最新）。
    func testMatchingMultipleResultsPreservesOrder() {
        let store = makeStore()
        store.add("三国演义") // 第三（最旧）
        store.add("三国志")   // 第二
        store.add("三国英雄") // 第一（最新）
        let matches = store.matching("三国")
        XCTAssertEqual(matches, ["三国英雄", "三国志", "三国演义"])
    }

    /// 无匹配返回空数组。
    func testMatchingNoResults() {
        let store = makeStore()
        store.add("三国演义")
        XCTAssertTrue(store.matching("西游").isEmpty)
    }

    /// 空白 query 不崩溃，返回全部。
    func testMatchingWhitespaceOnlyReturnsAll() {
        let store = makeStore()
        store.add("三国演义")
        XCTAssertEqual(store.matching("  "), ["三国演义"])
    }

    // MARK: - 收藏进度辅助：historyForFavorite 纯逻辑等价验证

    /// (src, albumId) 精确匹配应命中最近一条历史。
    func testHistoryLookupBySourceAndAlbumId() {
        let h1 = HistoryModel(src: "tingyou", albumId: 42, albumTitle: "三国", coverUrl: nil,
                              chapterIdx: 3, chapterTitle: "第三回", positionMs: 60_000,
                              durationMs: 300_000, detailPath: nil)
        let h2 = HistoryModel(src: "tingyou", albumId: 99, albumTitle: "水浒", coverUrl: nil,
                              chapterIdx: 1, chapterTitle: "第一回", positionMs: 0,
                              durationMs: 200_000, detailPath: nil)
        let histories = [h1, h2]
        let f = FavoriteModel(src: "tingyou", albumId: 42, title: "三国")
        let matched = histories.first { $0.src == f.src && $0.albumId == f.albumId }
        XCTAssertNotNil(matched)
        XCTAssertEqual(matched?.chapterTitle, "第三回")
    }

    /// 无匹配时应返回 nil。
    func testHistoryLookupNoMatchReturnsNil() {
        let histories: [HistoryModel] = []
        let f = FavoriteModel(src: "tingyou", albumId: 42, title: "三国")
        let matched = histories.first { $0.src == f.src && $0.albumId == f.albumId }
        XCTAssertNil(matched)
    }
}
