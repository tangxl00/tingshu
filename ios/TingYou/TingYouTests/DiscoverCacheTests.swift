import XCTest
@testable import TingYou

private struct Boom: Error {}

/// 增强 5.1 验收：发现页缓存写入与「优先读缓存」路径（协议注入假数据源）。
final class DiscoverCacheTests: XCTestCase {

    // MARK: - 假件

    /// 假数据源：可配置延迟，用于观测「缓存先行渲染 → 后台刷新替换」的中间态。
    final class FakeDiscoverSource: DiscoverDataLoading, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var loadCount = 0
        var delayNanos: UInt64 = 0
        var result = PagedResult<Album>(items: [], hasMore: false)

        func loadRank(section: String, page: Int) async throws -> PagedResult<Album> {
            if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
            lock.lock(); defer { lock.unlock() }
            loadCount += 1
            return result
        }
    }

    /// 假缓存：内存字典实现。
    final class FakeCache: DiscoverCacheStore, @unchecked Sendable {
        private let lock = NSLock()
        var storage: [String: [Album]] = [:]
        private(set) var removeAllCount = 0

        func saveSection(_ section: String, albums: [Album]) throws {
            lock.lock(); defer { lock.unlock() }
            storage[section] = albums
        }
        func loadSection(_ section: String) -> [Album]? {
            lock.lock(); defer { lock.unlock() }
            return storage[section]
        }
        func removeAll() {
            lock.lock(); defer { lock.unlock() }
            storage.removeAll(keepCapacity: false)
            removeAllCount += 1
        }
    }

    struct FailingSource: DiscoverDataLoading {
        func loadRank(section: String, page: Int) async throws -> PagedResult<Album> { throw Boom() }
    }

    // MARK: - 用例

    /// 启动先渲染缓存数据，网络返回后被静默刷新替换。
    func testLoadRankRendersCacheFirstThenRefreshes() async {
        let cachedAlbum = makeAlbum(id: 1, title: "缓存书")
        let freshAlbum = makeAlbum(id: 2, title: "新数据书")
        let source = FakeDiscoverSource()
        source.result = PagedResult(items: [freshAlbum], hasMore: false)
        source.delayNanos = 80_000_000 // 80ms，留出观测中间态的窗口
        let cache = FakeCache()
        cache.storage["recommend"] = [cachedAlbum]

        let vm = DiscoverViewModel()
        vm.attach(loader: source, cache: cache)

        let task = Task { await vm.loadRank(section: "recommend") }

        // build 20 必修 6：自旋等待改 expectation——慢机不再因固定迭代上限提前跳出误判。
        // 等待「列表第一次非空」这件事本身，超时兜底 5s；非空即断言此刻内容是缓存数据。
        let cacheRendered = expectation(description: "网络返回前列表应先渲染缓存数据")
        let observer = Task {
            while vm.albums.isEmpty { await Task.yield() }
            cacheRendered.fulfill()
        }
        await fulfillment(of: [cacheRendered], timeout: 5)
        observer.cancel()
        XCTAssertEqual(vm.albums.map(\.title), ["缓存书"], "等待网络期间应先显示缓存数据")

        _ = await task.value

        // 终态：被新数据替换，并写回缓存
        XCTAssertEqual(vm.albums.map(\.title), ["新数据书"])
        XCTAssertEqual(cache.storage["recommend"]?.map(\.title), ["新数据书"], "新数据应写回缓存")
        XCTAssertEqual(source.loadCount, 1)
    }

    /// 无缓存时正常走网络并写入缓存。
    func testLoadRankWritesCacheOnSuccess() async {
        let album = makeAlbum(id: 3, title: "网络书")
        let source = FakeDiscoverSource()
        source.result = PagedResult(items: [album], hasMore: false)
        let cache = FakeCache()

        let vm = DiscoverViewModel()
        vm.attach(loader: source, cache: cache)
        await vm.loadRank(section: "hot")

        XCTAssertEqual(vm.albums.map(\.title), ["网络书"])
        XCTAssertEqual(cache.storage["hot"]?.map(\.title), ["网络书"])
    }

    /// 网络失败时保留缓存内容不清屏。
    func testLoadRankKeepsCachedDataWhenRefreshFails() async {
        let failing = FailingSource()
        let cache = FakeCache()
        cache.storage["recommend"] = [makeAlbum(id: 9, title: "缓存书")]

        let vm = DiscoverViewModel()
        vm.attach(loader: failing, cache: cache)
        await vm.loadRank(section: "recommend")

        XCTAssertEqual(vm.albums.map(\.title), ["缓存书"], "刷新失败不应清掉缓存渲染的内容")
    }

    /// 磁盘缓存（临时目录）：写入-读回循环 + 未命中返回 nil。
    func testDiskCacheRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscoverCacheTests-\(UUID().uuidString)", isDirectory: true)
        let disk = DiskDiscoverCache(directory: dir)
        XCTAssertNil(disk.loadSection("recommend"), "未写入前应返回 nil")

        let albums = [makeAlbum(id: 1, title: "A"), makeAlbum(id: 2, title: "B")]
        try disk.saveSection("recommend", albums: albums)

        let loaded = disk.loadSection("recommend")
        XCTAssertEqual(loaded?.map(\.title), ["A", "B"], "写入后应能读回相同数据")
        XCTAssertEqual(loaded?.first?.source, "tingyou")

        disk.removeAll()
        XCTAssertNil(disk.loadSection("recommend"), "清空后应返回 nil")
        try? FileManager.default.removeItem(at: dir)
    }

    /// 磁盘缓存大小控制：超限触发淘汰路径且不崩溃。
    func testDiskCacheEvictsWhenOverCap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscoverCacheTests-\(UUID().uuidString)", isDirectory: true)
        // 上限 1 字节 → 任何写入都会触发淘汰路径
        let disk = DiskDiscoverCache(directory: dir, maxTotalBytes: 1)
        try disk.saveSection("recommend", albums: [makeAlbum(id: 1, title: "A")])
        // 总量已超限：读取不崩溃即可（最新文件可能已被淘汰）
        _ = disk.loadSection("recommend")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 辅助

    private func makeAlbum(id: Int64, title: String) -> Album {
        Album(albumId: id, title: title, author: nil, teller: nil, coverUrl: nil,
              intro: nil, category: nil, categoryId: nil, type: nil, typeId: nil,
              status: nil, chapterCount: nil, updatedAt: nil, playCount: nil,
              available: nil, source: "tingyou", detailPath: nil)
    }
}
