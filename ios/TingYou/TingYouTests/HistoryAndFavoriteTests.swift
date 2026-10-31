import XCTest
import SwiftData
@testable import TingYou

/// Bug 2 验收：播放历史按 (src, albumId) upsert、收藏写/删/复查（内存容器）。
final class HistoryAndFavoriteTests: XCTestCase {

    private var container: ModelContainer!
    private var repo: AlbumRepository!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: FavoriteModel.self, HistoryModel.self,
            ImportedBookModel.self, ImportedChapterModel.self,
            configurations: config)
        repo = await MainActor.run {
            AlbumRepository(apiClient: APIClient(), modelContext: self.container.mainContext)
        }
    }

    // MARK: - 历史 upsert

    /// 同一本书多次上报只保留一条记录，字段更新为最新。
    func testRecordHistoryUpsertsSameBook() async throws {
        let album = makeAlbum(id: 100, title: "医手遮天")
        let ch1 = Chapter(chapterId: 1, index: 0, title: "第01集", durationSec: 1800)
        let ch2 = Chapter(chapterId: 2, index: 1, title: "第02集", durationSec: 1750)

        await repo.recordHistory(album: album, chapter: ch1, positionMs: 1_000, durationMs: 1_800_000)
        await repo.recordHistory(album: album, chapter: ch2, positionMs: 2_000, durationMs: 1_750_000)

        let (count, latest) = try await fetchHistory(albumId: 100)
        XCTAssertEqual(count, 1, "同一本书应只保留一条历史记录")
        XCTAssertEqual(latest?.chapterTitle, "第02集", "应更新为最新章节")
        XCTAssertEqual(latest?.positionMs, 2_000, "应更新为最新进度")
        XCTAssertEqual(latest?.albumTitle, "医手遮天")
    }

    /// 不同书的记录互不影响。
    func testRecordHistoryDifferentBooksInsertSeparately() async throws {
        let a = makeAlbum(id: 201, title: "书A")
        let b = makeAlbum(id: 202, title: "书B")
        let ch = Chapter(chapterId: 1, index: 0, title: "第01集", durationSec: 1800)

        await repo.recordHistory(album: a, chapter: ch, positionMs: 100, durationMs: 1)
        await repo.recordHistory(album: b, chapter: ch, positionMs: 200, durationMs: 1)

        let (countA, _) = try await fetchHistory(albumId: 201)
        let (countB, _) = try await fetchHistory(albumId: 202)
        XCTAssertEqual(countA, 1)
        XCTAssertEqual(countB, 1)
        let total = try await historyTotal()
        XCTAssertEqual(total, 2, "两本书应有两条独立记录")
    }

    // MARK: - 收藏写/删/复查

    func testFavoriteAddRemoveAndRequery() async throws {
        let album = makeAlbum(id: 301, title: "收藏测试书")

        var isFav = await repo.isFavorite(src: "tingyou", albumId: 301)
        XCTAssertFalse(isFav, "初始应未收藏")

        await repo.addFavorite(album: album)
        isFav = await repo.isFavorite(src: "tingyou", albumId: 301)
        XCTAssertTrue(isFav, "写入后复查应为已收藏")

        await repo.removeFavorite(src: "tingyou", albumId: 301)
        isFav = await repo.isFavorite(src: "tingyou", albumId: 301)
        XCTAssertFalse(isFav, "删除后复查应为未收藏")
    }

    func testAddFavoriteIsIdempotent() async throws {
        let album = makeAlbum(id: 302, title: "幂等收藏书")
        await repo.addFavorite(album: album)
        await repo.addFavorite(album: album)
        let count = try await favoriteTotal()
        XCTAssertEqual(count, 1, "重复收藏应幂等跳过，不产生第二条记录")
    }

    /// build 19 P1-1 回归：同一音源收藏两本不同的书，两条都必须落库。
    /// 原缺陷：src / albumId 各挂一个 @Attribute(.unique)（逐属性独立唯一），
    /// 同源第二本书触发约束冲突、save 抛错被 try? 吞掉而静默丢失。
    func testFavoriteSameSourceDifferentBooksBothPersist() async throws {
        let a = makeAlbum(id: 501, title: "同源书A")
        let b = makeAlbum(id: 502, title: "同源书B")
        await repo.addFavorite(album: a)
        await repo.addFavorite(album: b)
        let favA = await repo.isFavorite(src: "tingyou", albumId: 501)
        let favB = await repo.isFavorite(src: "tingyou", albumId: 502)
        XCTAssertTrue(favA, "同源第一本收藏应存在")
        XCTAssertTrue(favB, "同源第二本书必须能收藏（原逐属性 unique 冲突导致静默丢失）")
        let total = try await favoriteTotal()
        XCTAssertEqual(total, 2, "两本书应各有一条收藏记录")
    }

    /// build 19 P1-2 回归：快速切章时历史最终必须是新章节，且写入严格串行。
    /// 原缺陷：recordHistory 直接 spawn 无序 Task，旧章节写任务可能后到后写。
    func testHistoryWriteSerializedLatestChapterWins() async throws {
        let fake = ProbeHistoryRecorder()
        fake.delayNanos = 50_000_000 // 每次写 50ms，放大交错窗口
        let pm = PlaybackManager(playbackRepository: nil)
        pm.historyRecorder = fake
        let album = makeAlbum(id: 401, title: "竞态测试书")
        let chapters = [
            Chapter(chapterId: 1, index: 0, title: "第01集", durationSec: 1800),
            Chapter(chapterId: 2, index: 1, title: "第02集", durationSec: 1750),
        ]
        // build 53 · 专项（C1）形态调整：原用例走 playQueue → play() 完整
        // 播放机器，自 b45 起在 CI 上 0.000s 进程崩溃（非断言失败，进程被
        // 杀、断言不执行）。静态审计历史队列路径（enqueueHistory /
        // drainHistoryQueue / historyLock 单任务排水）无 trap 类代码，崩溃面
        // 收敛在 AVFoundation 生命周期半边。按放行条件拆形：本用例改经
        // enqueueHistoryForTesting 直接驱动**生产同一份**队列实现（同锁、
        // 同单任务排水器），模拟「旧章 pause 写入 + 新章 loadCurrentChapter
        // 写入」两次入队接连发生——串行语义守卫不再与 AVPlayer 生命周期
        // 绑死，可独立稳定复现。
        pm.enqueueHistoryForTesting(album: album, chapter: chapters[0],
                                    positionMs: 1_000, durationMs: 1_800_000)
        pm.enqueueHistoryForTesting(album: album, chapter: chapters[1],
                                    positionMs: 2_000, durationMs: 1_750_000)
        // 等排水收敛（10s 上限）
        let deadline = Date().addingTimeInterval(10)
        while !pm.isHistoryWriteIdle && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(pm.isHistoryWriteIdle, "历史排水应在时限内收敛")
        XCTAssertEqual(fake.maxConcurrent, 1, "历史写入必须严格串行（同时至多一个在途）")
        XCTAssertEqual(fake.writes.last?.chapterTitle, "第02集",
                       "最终历史必须是新章节，旧章节写入不得后到后写")
    }

    // MARK: - 辅助

    /// P1-2 测试假件：记录写入、模拟慢写、追踪并发度。
    final class ProbeHistoryRecorder: PlaybackHistoryRecording, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var writes: [(chapterTitle: String, positionMs: Int64)] = []
        private var active = 0
        private(set) var maxConcurrent = 0
        var delayNanos: UInt64 = 0

        func recordHistory(album: Album, chapter: Chapter, positionMs: Int64, durationMs: Int64) async {
            lock.lock()
            active += 1
            maxConcurrent = max(maxConcurrent, active)
            lock.unlock()
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            lock.lock()
            writes.append((chapter.title, positionMs))
            active -= 1
            lock.unlock()
        }
    }

    private func makeAlbum(id: Int64, title: String) -> Album {
        Album(albumId: id, title: title, author: nil, teller: nil, coverUrl: nil,
              intro: nil, category: nil, categoryId: nil, type: nil, typeId: nil,
              status: nil, chapterCount: nil, updatedAt: nil, playCount: nil,
              available: nil, source: "tingyou", detailPath: nil)
    }

    private func fetchHistory(albumId: Int64) async throws -> (Int, HistoryModel?) {
        try await MainActor.run {
            let src = "tingyou"
            let fd = FetchDescriptor<HistoryModel>(
                predicate: #Predicate { $0.src == src && $0.albumId == albumId })
            let list = try self.container.mainContext.fetch(fd)
            return (list.count, list.first)
        }
    }

    private func historyTotal() async throws -> Int {
        try await MainActor.run {
            try self.container.mainContext.fetchCount(FetchDescriptor<HistoryModel>())
        }
    }

    private func favoriteTotal() async throws -> Int {
        try await MainActor.run {
            try self.container.mainContext.fetchCount(FetchDescriptor<FavoriteModel>())
        }
    }
}
