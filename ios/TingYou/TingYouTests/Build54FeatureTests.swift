import XCTest
import SwiftData
@testable import TingYou

/// build 54 · 需求 a/b/c/d/e（历史进度定位）的验收用例。
///
/// 覆盖口径（对应任务验收清单）：
/// - a/b 打开书（书架 / 收藏 / 历史）定位到上次章节 + 位置：`OpenResumePlanner.plan`
///   产出的 arrayPosition / startPosMs，以及播放器按该位置装载的实际落点。
/// - c 数据源 = **合并后的本地真相**（SyncEngine 按 `updated_at` LWW 落库），
///   云端较新取云、本地较新取本地；`chapter_idx` 0 基 ↔ 源原生章号换算后
///   章号不漂移（跨端构造：云端 0 基 29 → tingyou 第 30 章 → 数组位置 29）。
/// - d 无历史 → plan 为 nil，不定位（行为不变）。
/// - e 打开即到位：`shouldPrepare` 静默装载决策 + 起播位置夹取（含 1 秒余量，
///   避免夹到章尾立刻自动跳章）。
///
/// 非行为级用例共 2 条，均在「MARK: - 接线守卫（非行为级，如实标注）」分区内，
/// 只做源码形态守卫（单测沙箱无 SwiftUI 视图宿主，`ScrollViewProxy.scrollTo` 与
/// `onChange` 生命周期无法驱动）：
/// - `testAlbumScreenConsumesPlannerSilently`（#16，#54 的字符串扫描）
/// - `testRestorePathsUseArrayPositionSemantics`（#17 的字符串扫描）
///
/// build 55 返修（b54 复检 P1-1）：#15 原名为 `…Silently` 却**没传 silentWrite**
/// （默认 false）、且 `historyRecorder` 为 nil（`recordHistory` 全程 no-op）——
/// 等于守卫零覆盖。现改为真行为级：注入可记录 recorder + 显式 `silentWrite: true`，
/// 断言「recorder 零调用 且 HistoryModel.updatedAt 未被顶成 now」，并配一条
/// `silentWrite: false` 的反证用例（证明测试抓得住回归）。
///
/// build 55 二/三/四轮（CI 0.000s 进程崩溃取证）：P1-1 反证与 P1-2 闸门用例
/// 最初放在本类（setUp 持有内存 ModelContainer）。二轮「探针独享 + 直调落库」、
/// 三轮「非隔离 + @MainActor SwiftData helper 收口」两种形态下，NonSilentLoad /
/// PauseChannel / Periodic 三条都在 CI 0.000s 整进程被杀（test.log 无断言文本，
/// 两轮 6/6 复现；b54 基线 332/0 全绿）。三轮后的差分取证把崩溃组合收敛为
/// 「`recordHistory` 完整路径执行到写 + 测试类持有 ModelContainer」——同一套
/// 机器在**无容器**的 SkipSettingsTests（recordHistory 全程 + 探针写，历轮全绿）
/// 与**有容器**的 HistoryAndFavoriteTests（经 enqueueHistoryForTesting 驱动同一份
/// 排水实现，历轮全绿）分别稳定通过；本类不触发写的 PM 用例（ApplyPlan /
/// DeinitChannel）也全绿——三轮的隔离域假设随之证伪，容器组合是唯一同时命中
/// 6 次崩溃、且所有全绿用例都避开其一的差分项。按 b53 C1「拆形」先例收口：
/// 三条闸门行为用例移入**无容器**的 `Build55HistoryGateTests`（SkipSettingsTests
/// 同构形态）；DB 侧证据留本类走**无 PM 直调**形态——静默不顶新由
/// `testApplyPlanLoadsHistoricalChapterSilently`（updatedAt 保持 300）承担，
/// 反证顶新由 `testNonSilentRepoWriteBumpsUpdatedAt`（直调生产 repo）承担。
/// `testPausedForeignQueueIsNotTornDown` 二轮已改决策级纯函数 + 接线守卫并通过。
final class Build54FeatureTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SyncLocalStore!
    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        RetryStubURLProtocol.reset()
        suiteName = "b54-resume-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SyncLocalStore(defaults: defaults)
        container = try ModelContainer(
            for: FavoriteModel.self, HistoryModel.self,
            ImportedBookModel.self, ImportedChapterModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        RetryStubURLProtocol.reset()
        container = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - 工具

    private func makeAlbum(src: String, albumId: Int64, title: String = "测试书") -> Album {
        Album(albumId: albumId, title: title, author: nil, teller: nil,
              coverUrl: nil, intro: nil, category: nil, categoryId: nil,
              type: nil, typeId: nil, status: nil, chapterCount: nil,
              updatedAt: nil, playCount: nil, available: true,
              source: src, detailPath: nil)
    }

    /// 1 基源（tingyou）章节：index 1..n
    private func oneBasedChapters(_ n: Int, durationSec: Int? = nil) -> [Chapter] {
        (1...n).map { Chapter(chapterId: Int64($0), index: $0,
                              title: "第\($0)章", durationSec: durationSec) }
    }

    /// 0 基源（bili / 易听书）章节：index 0..n-1
    private func zeroBasedChapters(_ n: Int, durationSec: Int? = nil) -> [Chapter] {
        (0..<n).map { Chapter(chapterId: Int64($0) + 1, index: $0,
                              title: "第\($0 + 1)集", durationSec: durationSec) }
    }

    private func snapshot(src: String, albumId: Int64, chapterIdx: Int,
                          positionMs: Int64, durationMs: Int64 = 0,
                          title: String = "", updatedAt: Int64) -> HistorySnapshot {
        HistorySnapshot(src: src, albumId: albumId, chapterIdx: chapterIdx,
                        chapterTitle: title, positionMs: positionMs,
                        durationMs: durationMs, updatedAt: updatedAt)
    }

    @MainActor
    private func allHistory(_ ctx: ModelContext) -> [HistoryModel] {
        (try? ctx.fetch(FetchDescriptor<HistoryModel>())) ?? []
    }

    /// 埋一条「云端合并后的较新进度」，用于验证静默装载**不得**把它顶成 now。
    @MainActor
    private func seedHistory(_ ctx: ModelContext, album: Album,
                            chapterIdx: Int, chapterTitle: String,
                            positionMs: Int64, updatedAt: Int64) {
        ctx.insert(HistoryModel(src: album.source, albumId: album.albumId,
                                albumTitle: album.title, coverUrl: album.coverUrl,
                                chapterIdx: chapterIdx, chapterTitle: chapterTitle,
                                positionMs: positionMs, durationMs: 0,
                                detailPath: album.detailPath, updatedAt: updatedAt))
        try? ctx.save()
    }

    /// 等历史串行排水结束（`recordHistory` 是异步入队 + 单任务排水）。
    /// 非隔离形态：`isHistoryWriteIdle` 由 `historyLock` 保护，任意隔离域可安全轮询
    /// （build 55 三轮：@MainActor 等待器会迫使闸门用例挂主 actor，见类头注释）。
    private func waitForHistoryIdle(_ pm: PlaybackManager) async throws {
        for _ in 0..<200 {
            if pm.isHistoryWriteIdle { return }
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        XCTFail("历史排水 1s 内未空闲（isHistoryWriteIdle 恒 false）")
    }

    /// 可记录的历史写入探针（零调用可断言）。与 `HistoryAndFavoriteTests` 里的同名
    /// 类型各自嵌套在不同测试类内，互不冲突。
    final class ProbeHistoryRecorder: PlaybackHistoryRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [(chapterTitle: String, positionMs: Int64)] = []

        var writes: [(chapterTitle: String, positionMs: Int64)] {
            lock.lock(); defer { lock.unlock() }
            return _writes
        }

        func recordHistory(album: Album, chapter: Chapter,
                           positionMs: Int64, durationMs: Int64) async {
            lock.lock()
            _writes.append((chapter.title, positionMs))
            lock.unlock()
        }
    }

    /// 扇出：同一笔历史同时交给「探针」（统计调用次数）与「真 repo」（真落库，
    /// 于是 `HistoryModel.updatedAt` 是可读回的真实产物）。
    final class RecordingFanout: PlaybackHistoryRecording, @unchecked Sendable {
        private let targets: [any PlaybackHistoryRecording]

        init(_ targets: [any PlaybackHistoryRecording]) { self.targets = targets }

        func recordHistory(album: Album, chapter: Chapter,
                           positionMs: Int64, durationMs: Int64) async {
            for t in targets {
                await t.recordHistory(album: album, chapter: chapter,
                                      positionMs: positionMs, durationMs: durationMs)
            }
        }
    }

    /// 跨线程计数（deinit 可能在非主线程触发闸门回调）。
    final class HitCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var hits: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }

    // MARK: - 本地进度存取 round-trip

    /// 需求 a/b 基础：播放历史经 AlbumRepository 落库后，能被打开书定位链路原样读出
    /// （章号、章标题、位置、时长、updatedAt 全一致）。
    @MainActor
    func testLocalHistoryRoundTripFeedsOpenPlanner() async throws {
        let ctx = container.mainContext
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5401, title: "三体")
        let repo = AlbumRepository(apiClient: APIClient(session: RetryStubURLProtocol.makeSession()),
                                   modelContext: ctx)
        let chapter = Chapter(chapterId: 12, index: 12, title: "第12章", durationSec: 1_800)
        await repo.recordHistory(album: album, chapter: chapter,
                                 positionMs: 725_000, durationMs: 1_800_000)

        let rows = allHistory(ctx)
        XCTAssertEqual(rows.count, 1, "同一本书只保留一条历史（upsert）")
        let stored = try XCTUnwrap(rows.first)
        XCTAssertEqual(stored.chapterIdx, 12, "历史章号按源原生口径存（tingyou 1 基）")
        XCTAssertEqual(stored.positionMs, 725_000, "历史位置往返不失真")
        XCTAssertEqual(stored.chapterTitle, "第12章")

        let chapters = oneBasedChapters(40, durationSec: 1_800)
        let plan = OpenResumePlanner.plan(album: album, chapters: chapters,
                                          snapshots: [HistorySnapshot(stored)],
                                          anchor: nil, isPlaying: false)
        let unwrapped = try XCTUnwrap(plan, "有历史必须产出定位结论")
        XCTAssertEqual(unwrapped.arrayPosition, 11, "第 12 章（1 基）→ 数组位置 11（0 基）")
        XCTAssertEqual(unwrapped.chapter.index, 12)
        XCTAssertEqual(unwrapped.startPosMs, 725_000, "起播位置 = 历史位置（时长未越界不改写）")
        XCTAssertTrue(unwrapped.shouldPrepare, "播放器空闲 → 需要静默装载到历史章")
    }

    /// 再播一次（换章 + 推进位置）后重新落库：仍是同一条记录且被更新（不是新增一条）。
    @MainActor
    func testLocalHistoryUpsertAfterProgressAdvance() async throws {
        let ctx = container.mainContext
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5402)
        let repo = AlbumRepository(apiClient: APIClient(session: RetryStubURLProtocol.makeSession()),
                                   modelContext: ctx)
        await repo.recordHistory(album: album,
                                 chapter: Chapter(chapterId: 1, index: 1, title: "第1章", durationSec: nil),
                                 positionMs: 30_000, durationMs: 0)
        await repo.recordHistory(album: album,
                                 chapter: Chapter(chapterId: 20, index: 20, title: "第20章", durationSec: nil),
                                 positionMs: 500_000, durationMs: 0)
        let rows = allHistory(ctx)
        XCTAssertEqual(rows.count, 1, "按 (src, albumId) upsert，不得留两条")
        XCTAssertEqual(rows[0].chapterIdx, 20)
        XCTAssertEqual(rows[0].positionMs, 500_000)
    }

    // MARK: - 需求 c · 云端较新取云

    /// 跨端续播正向：PC 已推到第 30 章（云端 `chapter_idx = 29`，0 基）且云端
    /// `updated_at` 较新 → 合并后本地取云，打开书直接定位到第 30 章的第 29 个
    /// 数组位置 + 云端的播放位置（**不得回退到本地旧的第 25 章**）。
    @MainActor
    func testCloudNewerProgressWinsOverLocal() async throws {
        let ctx = container.mainContext
        let src = SourceRegistry.TINGYOU
        let albumId: Int64 = 5403
        // 本地旧进度：第 25 章，updated_at = 1000
        ctx.insert(HistoryModel(src: src, albumId: albumId, albumTitle: "跨端书",
                                coverUrl: nil, chapterIdx: 25, chapterTitle: "第25章",
                                positionMs: 100_000, durationMs: 0, detailPath: nil,
                                updatedAt: 1_000))
        try ctx.save()

        login(accessExpiresInMs: 10 * 60_000)
        // 云端新进度：0 基 chapter_idx = 29（= 第 30 章），updated_at = 2000
        let cloudRow: [String: Any] = [
            "book_key": "\(src):\(albumId)", "source": src, "title": "跨端书",
            "chapter_idx": 29, "position_ms": 612_000, "duration_ms": 0,
            "updated_at": 2_000, "last_client_at": 2_000,
        ]
        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/push":
                return Self.ok(#"{"server_seq":21,"results":[],"processed":0,"submitted":0}"#)
            case "sync/v1/pull":
                return Self.ok(Self.pullJSON(serverSeq: 21, favorites: [], progress: [cloudRow]))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        let engine = makeEngine(modelContext: ctx)
        engine.retryBackoffOverride = [.seconds(600)]
        await engine.syncNow()
        engine.stopRetry()

        let stored = try XCTUnwrap(allHistory(ctx).first, "合并后必须仍有一条本书记录")
        XCTAssertEqual(stored.chapterIdx, 30,
                       "云端 0 基 29 → tingyou 1 基第 30 章（跨端不漂移）")
        XCTAssertEqual(stored.positionMs, 612_000, "云端较新 → 位置取云")

        let chapters = oneBasedChapters(60, durationSec: nil)
        let plan = try XCTUnwrap(OpenResumePlanner.plan(album: makeAlbum(src: src, albumId: albumId),
                                                        chapters: chapters,
                                                        snapshots: [HistorySnapshot(stored)],
                                                        anchor: nil, isPlaying: false))
        XCTAssertEqual(plan.arrayPosition, 29, "第 30 章 → 数组位置 29（0 基口径）")
        XCTAssertEqual(plan.chapter.title, "第30章")
        XCTAssertEqual(plan.startPosMs, 612_000, "定位起播位置 = 云端进度（不回到第 25 章）")
    }

    /// 需求 c 禁止的回退形态：云端记录**更旧**（updated_at 小于本地）时不得覆盖本地。
    @MainActor
    func testOlderCloudProgressDoesNotRegressLocal() async throws {
        let ctx = container.mainContext
        let src = SourceRegistry.TINGYOU
        let albumId: Int64 = 5404
        ctx.insert(HistoryModel(src: src, albumId: albumId, albumTitle: "本地较新",
                                coverUrl: nil, chapterIdx: 41, chapterTitle: "第41章",
                                positionMs: 300_000, durationMs: 0, detailPath: nil,
                                updatedAt: 5_000))
        try ctx.save()

        login(accessExpiresInMs: 10 * 60_000)
        let staleRow: [String: Any] = [
            "book_key": "\(src):\(albumId)", "source": src, "title": "云端旧进度",
            "chapter_idx": 24, "position_ms": 90_000, "duration_ms": 0,
            "updated_at": 1_000, "last_client_at": 1_000,
        ]
        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/push":
                return Self.ok(#"{"server_seq":22,"results":[],"processed":0,"submitted":0}"#)
            case "sync/v1/pull":
                return Self.ok(Self.pullJSON(serverSeq: 22, favorites: [], progress: [staleRow]))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        let engine = makeEngine(modelContext: ctx)
        engine.retryBackoffOverride = [.seconds(600)]
        await engine.syncNow()
        engine.stopRetry()

        let stored = try XCTUnwrap(allHistory(ctx).first)
        XCTAssertEqual(stored.chapterIdx, 41, "本地较新 → 不被云端旧进度覆盖（禁止跨端回退）")
        XCTAssertEqual(stored.positionMs, 300_000)

        let chapters = oneBasedChapters(60)
        let plan = try XCTUnwrap(OpenResumePlanner.plan(album: makeAlbum(src: src, albumId: albumId),
                                                        chapters: chapters,
                                                        snapshots: [HistorySnapshot(stored)],
                                                        anchor: nil, isPlaying: false))
        XCTAssertEqual(plan.arrayPosition, 40, "定位在第 41 章（数组位置 40），不回退")
    }

    /// 同一本书存在多条历史（历史遗留 / 合并残留）时取 `updated_at` 最新者
    /// ——与同步 LWW 口径一致。
    @MainActor
    func testPlannerPicksNewestSnapshotAmongDuplicates() {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5405)
        let snaps = [
            snapshot(src: SourceRegistry.TINGYOU, albumId: 5405, chapterIdx: 3, positionMs: 10_000, updatedAt: 100),
            snapshot(src: SourceRegistry.TINGYOU, albumId: 5405, chapterIdx: 33, positionMs: 400_000, updatedAt: 900),
            snapshot(src: SourceRegistry.TINGYOU, albumId: 5405, chapterIdx: 7, positionMs: 20_000, updatedAt: 500),
        ]
        let target = OpenResumePlanner.target(src: SourceRegistry.TINGYOU, albumId: 5405, in: snaps)
        XCTAssertEqual(target?.chapterIdx, 33, "取 updatedAt 最新一条")
        XCTAssertEqual(target?.positionMs, 400_000)
        let plan = OpenResumePlanner.plan(album: album, chapters: oneBasedChapters(50),
                                          snapshots: snaps, anchor: nil, isPlaying: false)
        XCTAssertEqual(plan?.arrayPosition, 32)
    }

    // MARK: - 需求 c · 0 基不漂移（0 基源 / 1 基源各一条）

    /// 0 基源（bili）：云端 0 基章号与本地源原生章号口径相同，不得被二次换算。
    @MainActor
    func testZeroBasedSourceChapterIdxNotShifted() {
        let album = makeAlbum(src: SourceRegistry.BILI, albumId: 5406)
        let chapters = zeroBasedChapters(20)
        let snaps = [snapshot(src: SourceRegistry.BILI, albumId: 5406, chapterIdx: 9,
                              positionMs: 120_000, updatedAt: 800)]
        let plan = OpenResumePlanner.plan(album: album, chapters: chapters,
                                          snapshots: snaps, anchor: nil, isPlaying: false)
        XCTAssertEqual(plan?.arrayPosition, 9, "0 基源：章号 9 → 位置 9（无偏移）")
        XCTAssertEqual(plan?.chapter.index, 9, "章号 0 基不漂移")
    }

    /// 1 基源（tingyou）：本地第 k 章（k ≥ 2）必须落到数组位置 k-1。
    /// 这条正是 b36 遗留缺陷的回归守卫：旧 `startIdx:` 双语义会落到 k-2（早一章）。
    @MainActor
    func testOneBasedSourceChapterIdxLandsOnSameChapter() {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5407)
        let chapters = oneBasedChapters(30)
        for k in [2, 5, 17, 30] {
            let plan = OpenResumePlanner.plan(
                album: album, chapters: chapters,
                snapshot: snapshot(src: SourceRegistry.TINGYOU, albumId: 5407,
                                   chapterIdx: k, positionMs: 0, updatedAt: 700),
                anchor: nil, isPlaying: false)
            XCTAssertEqual(plan?.arrayPosition, k - 1, "第 \(k) 章 → 数组位置 \(k - 1)")
            XCTAssertEqual(plan?.chapter.index, k, "落点章号必须与历史章号相同（不得早一章）")
        }
    }

    /// 播放器侧行为级取证：`.arrayPosition` 与 `.indexValue` 两种语义在 1 基源上
    /// 相差正好一章——用真实 `prepareQueue` 装载后的 `currentChapterIdx` / 标题断言。
    @MainActor
    func testPlaybackManagerArrayPositionAvoidsOffByOneOnOneBasedSource() {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5408)
        let chapters = oneBasedChapters(6)

        let pm = PlaybackManager(playbackRepository: nil)
        // 恢复链路语义（修复后）：历史第 4 章 → arrayPosition 3
        pm.prepareQueue(album: album, chapters: chapters, start: .arrayPosition(3), startPosMs: 444_000)
        XCTAssertEqual(pm.currentChapterIdx, 3, "arrayPosition 3 → 数组位置 3")
        XCTAssertEqual(pm.currentChapterTitle, "第4章", "落点必须是历史那次收听的章")

        // 旧语义（`startIdx:` 按章号值匹配）：位置 3 被当成章号 3 → 落到数组位置 2（早一章）
        let legacy = PlaybackManager(playbackRepository: nil)
        legacy.prepareQueue(album: album, chapters: chapters, startIdx: 3)
        XCTAssertEqual(legacy.currentChapterIdx, 2,
                       "对照：旧 startIdx 语义在 1 基源上早一章（这就是本案修复的缺陷形态）")
    }

    // MARK: - 需求 d · 无历史行为不变

    /// 新书 / 清过数据的书：没有历史 → 不产出定位结论 → 打开后停在第 1 章（原行为）。
    func testNoHistoryProducesNoResumePlan() {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5409)
        let chapters = oneBasedChapters(12)
        XCTAssertNil(OpenResumePlanner.plan(album: album, chapters: chapters, snapshots: [],
                                            anchor: nil, isPlaying: false),
                     "无历史不得定位（需求 d）")
        XCTAssertNil(OpenResumePlanner.plan(album: album, chapters: chapters, snapshot: nil,
                                            anchor: nil, isPlaying: false),
                     "单条历史入口同样返回 nil")
        // 其它书的进度不得串到本书
        let other = [snapshot(src: SourceRegistry.TINGYOU, albumId: 5500, chapterIdx: 9,
                              positionMs: 1_000, updatedAt: 999)]
        XCTAssertNil(OpenResumePlanner.plan(album: album, chapters: chapters, snapshots: other,
                                            anchor: nil, isPlaying: false),
                     "别的书的历史不得用于定位本书")
        // 空章节列表（加载失败）→ 不定位、不越界
        XCTAssertNil(OpenResumePlanner.plan(album: album, chapters: [], snapshots: other,
                                            anchor: nil, isPlaying: false))
    }

    // MARK: - 需求 e · 起播位置夹取

    func testClampPositionWithinDurationIsUnchanged() {
        XCTAssertEqual(OpenResumePlanner.clampPosition(500_000, chapterDurationSec: 1_800), 500_000)
        XCTAssertEqual(OpenResumePlanner.clampPosition(0, chapterDurationSec: 1_800), 0)
        XCTAssertEqual(OpenResumePlanner.clampPosition(-5, chapterDurationSec: 1_800), 0, "负值归零")
    }

    /// 历史时长与当前源该章时长不一致（换源 / 补章）：夹到有效范围并留 1 秒余量，
    /// 避免夹到正好章尾触发 `onChapterFinished` 自动跳章。
    func testClampPositionBeyondDurationKeepsMargin() {
        let clamped = OpenResumePlanner.clampPosition(1_900_000, chapterDurationSec: 1_800)
        XCTAssertEqual(clamped, 1_799_000, "越界夹到 时长-1s")
        XCTAssertLessThan(clamped, 1_800_000, "不得等于章尾（否则立刻自动跳下一章）")
        // 章时长未知（bili / 易听书无 durationSec）：只保证非负，运行期由 seek 再夹
        XCTAssertEqual(OpenResumePlanner.clampPosition(9_999_000, chapterDurationSec: nil), 9_999_000)
        XCTAssertEqual(OpenResumePlanner.clampPosition(9_999_000, chapterDurationSec: 0), 9_999_000)
    }

    /// 夹取结果必须真的进入定位结论（`plan.startPosMs`），而不是只活在校验函数里。
    func testPlanCarriesClampedStartPosition() {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5410)
        let chapters = oneBasedChapters(10, durationSec: 1_200)
        let plan = OpenResumePlanner.plan(
            album: album, chapters: chapters,
            snapshot: snapshot(src: SourceRegistry.TINGYOU, albumId: 5410,
                               chapterIdx: 6, positionMs: 5_000_000, updatedAt: 100),
            anchor: nil, isPlaying: false)
        XCTAssertEqual(plan?.arrayPosition, 5)
        XCTAssertEqual(plan?.startPosMs, 1_199_000, "越界历史位置被夹到 1200s-1s")
    }

    // MARK: - 需求 e · 静默装载决策

    /// 正在播放别的书：打开某书详情页不得打断正在听的音频（不重装载）。
    func testShouldPrepareSkipsWhilePlaying() {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5411)
        let chapters = oneBasedChapters(10)
        let target = ResumeTarget(chapterIdx: 4, chapterTitle: "第4章", positionMs: 60_000, durationMs: 0)
        let foreignAnchor = QueueAnchor(src: SourceRegistry.TINGYOU, albumId: 9999, arrayPosition: 2)
        XCTAssertFalse(OpenResumePlanner.shouldPrepare(anchor: foreignAnchor, isPlaying: true,
                                                       album: album, target: target, chapters: chapters),
                       "正在播放时不得抢占播放器")
        XCTAssertFalse(OpenResumePlanner.shouldPrepare(anchor: nil, isPlaying: true,
                                                       album: album, target: target, chapters: chapters))
    }

    /// 已装载本书且正停在目标章：不重复装载（避免重新取流 + 重写历史）。
    func testShouldPrepareSkipsWhenAlreadyOnTargetChapter() {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5412)
        let chapters = oneBasedChapters(10)
        let target = ResumeTarget(chapterIdx: 7, chapterTitle: "第7章", positionMs: 60_000, durationMs: 0)
        let anchor = QueueAnchor(src: SourceRegistry.TINGYOU, albumId: 5412, arrayPosition: 6)
        XCTAssertFalse(OpenResumePlanner.shouldPrepare(anchor: anchor, isPlaying: false,
                                                       album: album, target: target, chapters: chapters))
        // 本书但停在别的章 → 需要（重新）装载到历史章
        let wrongChapter = QueueAnchor(src: SourceRegistry.TINGYOU, albumId: 5412, arrayPosition: 2)
        XCTAssertTrue(OpenResumePlanner.shouldPrepare(anchor: wrongChapter, isPlaying: false,
                                                      album: album, target: target, chapters: chapters))
        // build 55 · P2-4：暂停态下播放器里是**另**一本书 / 另**一**个源的书 →
        // 不得装载本页，否则会把用户暂停中的那份队列掀掉（b54 缺陷；
        // 详见下方 `testPausedForeignQueueIsNotTornDown`）。这里断言 false = 保留队列。
        let otherAlbum = QueueAnchor(src: SourceRegistry.TINGYOU, albumId: 9999, arrayPosition: 6)
        XCTAssertFalse(OpenResumePlanner.shouldPrepare(anchor: otherAlbum, isPlaying: false,
                                                       album: album, target: target, chapters: chapters),
                       "暂停态下的别的书：保留其队列，不抢占播放器（P2-4）")
        // 同 id 不同源 → 不同书
        let otherSource = QueueAnchor(src: SourceRegistry.BILI, albumId: 5412, arrayPosition: 6)
        XCTAssertFalse(OpenResumePlanner.shouldPrepare(anchor: otherSource, isPlaying: false,
                                                       album: album, target: target, chapters: chapters),
                       "同 id 不同源＝另一本书：同样保留队列（P2-4）")
    }

    /// build 55 · P2-4 回归：暂停态播放器里是**别的书**时打开本页，
    /// `shouldPrepare` 必须拒绝装载（false ⇒ AlbumScreen 不调 prepareQueue ⇒
    /// 暂停中的 `currentAlbum` / `currentChapters` 原样保留；b54 会整队替换）。
    ///
    /// 拆形说明（build 55 二轮 · CI 崩溃修复）：初版真构造 PM + `prepareQueue`
    /// 后跨隔离读 PM 状态，CI 0.000s 进程级崩溃（该用例甚至没挂 recorder）；
    /// 现拆为 ① 决策级纯函数断言（与 `testShouldPrepareSkips…` 同款稳定形态）
    /// ② 接线守卫（`queueAnchorForThisAlbum()` 必须返回播放器**实际装载态**、
    /// `prepareQueue` 必须只在 `plan.shouldPrepare` 为真时被调用）。
    /// 两段合起来 = 决策不抢占 + 决策真的挡得住装载 ⇒ 队列不被掀掉。
    func testPausedForeignQueueIsNotTornDown() throws {
        // ① 决策级：锚点 = 播放器实际装载的另一本书（tingyou · 5420 · 数组位置 9）
        let opening = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5421, title: "打开的这本书")
        let target = ResumeTarget(chapterIdx: 4, chapterTitle: "第4章", positionMs: 60_000, durationMs: 0)
        let foreignAnchor = QueueAnchor(src: SourceRegistry.TINGYOU, albumId: 5420, arrayPosition: 9)
        XCTAssertFalse(OpenResumePlanner.shouldPrepare(anchor: foreignAnchor, isPlaying: false,
                                                       album: opening, target: target,
                                                       chapters: oneBasedChapters(30)),
                       "暂停态别书：不得装载（P2-4）——决策 false 即队列保留")

        // ② 接线守卫：决策 false 必须真的挡住 prepareQueue（否则决策白做）
        let src = try Self.source("TingYou/UI/Album/AlbumScreen.swift")
        XCTAssertTrue(src.contains("if plan.shouldPrepare, let pm"),
                      "prepareQueue 必须被 shouldPrepare 决策守住（false 不得触碰播放器）")
        XCTAssertTrue(src.contains("anchor: queueAnchorForThisAlbum()"),
                      "锚点必须经 queueAnchorForThisAlbum() 取播放器实际装载态")
        XCTAssertTrue(src.contains("guard let pm = container?.playbackManager, let cur = pm.currentAlbum"),
                      "queueAnchorForThisAlbum 必须读 currentAlbum（含装的是别的书的情形，b54 缺陷点）")
    }

    /// 「打开即到位」整体链路 + **silentWrite 真行为级取证**（build 55 · 复检 P1-1）。
    ///
    /// b54 形态的缺陷（复检报告 2b 第 15 行、3b 末段）：本用例名为 `…Silently`，
    /// 但 ① 调 `prepareQueue` 时**没传 `silentWrite`**（默认 false），②
    /// `PlaybackManager(playbackRepository: nil)` 使 `historyRecorder` 为 nil，
    /// `recordHistory` 全程 no-op——于是「写了没写」在两种实现下都无差别，
    /// 守卫形同零覆盖。
    ///
    /// build 55 改为真行为级，三件事同时成立：
    /// - 注入**可记录**的 recorder（真 `AlbumRepository` + 内存 SwiftData，落库与
    ///   `updatedAt` 都是真实产物，不是探针自报）；
    /// - 显式传 `silentWrite: true`；
    /// - 断言 ① recorder 零调用、② `HistoryModel.updatedAt` **未被顶成现在**
    ///   （该行是预先埋入的「云端较新」进度，updatedAt=300）。
    @MainActor
    func testApplyPlanLoadsHistoricalChapterSilently() async throws {
        let ctx = container.mainContext
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5413)
        let chapters = oneBasedChapters(15, durationSec: 1_500)
        let plan = try XCTUnwrap(OpenResumePlanner.plan(
            album: album, chapters: chapters,
            snapshot: snapshot(src: SourceRegistry.TINGYOU, albumId: 5413,
                               chapterIdx: 11, positionMs: 480_000, updatedAt: 300),
            anchor: nil, isPlaying: false))
        XCTAssertTrue(plan.shouldPrepare)

        // 埋一条「云端合并后的较新进度」：第 11 章 / 480s / updatedAt=300。
        seedHistory(ctx, album: album, chapterIdx: 11, chapterTitle: "第11章",
                    positionMs: 480_000, updatedAt: 300)
        let before = try XCTUnwrap(allHistory(ctx).first, "埋入行必须可读回")
        XCTAssertEqual(before.updatedAt, 300, "前置：updatedAt 是历史值，不是 now")

        let recorder = ProbeHistoryRecorder()
        let repo = AlbumRepository(apiClient: APIClient(session: RetryStubURLProtocol.makeSession()),
                                   modelContext: ctx)
        let pm = PlaybackManager(playbackRepository: nil)
        // 双通道取证：真 repo（落库可读回 updatedAt）+ 探针（统计调用次数，零调用可断言）
        pm.historyRecorder = RecordingFanout([recorder, repo])

        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(plan.arrayPosition),
                        startPosMs: plan.startPosMs,
                        silentWrite: true)
        try await waitForHistoryIdle(pm)

        XCTAssertEqual(pm.currentChapterIdx, 10, "打开即定位到第 11 章（数组位置 10）")
        XCTAssertEqual(pm.currentChapterTitle, "第11章")
        XCTAssertFalse(pm.isPlaying, "静默装载不出声（需求 e：不制造声音闪断）")
        // 起播位置经片头跳过决策后仍是历史位置（恢复不被片头跳过覆盖）
        XCTAssertEqual(PlaybackManager.chapterStartMs(startPosMs: plan.startPosMs, introSec: 30),
                       plan.startPosMs, "有历史位置时片头跳过不得覆盖")

        // —— P1-1 核心断言 ——
        XCTAssertEqual(recorder.writes.count, 0, "silentWrite 装载不得写历史（recorder 零调用）")
        let after = try XCTUnwrap(allHistory(ctx).first)
        XCTAssertEqual(after.updatedAt, 300,
                       "静默装载不得把 updatedAt 顶成 now（否则 LWW 翻成本地较新，跨端续播回退）")
        XCTAssertEqual(after.positionMs, 480_000, "进度不得被装载位置覆盖")
        XCTAssertEqual(after.chapterIdx, 11, "章号不得被改写")
    }

    /// **反证用例 · DB 半边**（build 55 · 复检 P1-1）：P1-1 要求的反证是
    /// 「`silentWrite: false` → 写确实发生 且 `updatedAt` 变化」。四轮拆形后由
    /// 两条用例共同构成（工程原因见类头「二/三/四轮」段——闸门行为与 ModelContainer
    /// 同进程会 0.000s 崩溃，无法在一条用例里既走 PM 闸门又读 DB 行）：
    /// ① 「写发生了」：`Build55HistoryGateTests.testNonSilentLoadEnqueuesHistoryWrite`
    ///    （真闸门 + 探针出口，非静默装载必须排出恰一次写）；
    /// ② 「updatedAt 顶新」（本用例）：同一份生产 `AlbumRepository.recordHistory`
    ///    直调（`testLocalHistoryRoundTrip…` 先例形态，无 PlaybackManager），
    ///    断言章号/位置按用户动作落、`updatedAt` 被 now 覆盖。
    /// 守卫被误改成「非静默也不写」→ ① 变红；repo 丢了顶新语义 → ② 变红。
    @MainActor
    func testNonSilentRepoWriteBumpsUpdatedAt() async throws {
        let ctx = container.mainContext
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5419)
        let chapters = oneBasedChapters(15, durationSec: 1_500)
        seedHistory(ctx, album: album, chapterIdx: 11, chapterTitle: "第11章",
                    positionMs: 480_000, updatedAt: 300)
        let before = try XCTUnwrap(allHistory(ctx).first)
        XCTAssertEqual(before.updatedAt, 300, "前置：updatedAt 是历史值，不是 now")

        let repo = AlbumRepository(apiClient: APIClient(session: RetryStubURLProtocol.makeSession()),
                                   modelContext: ctx)
        await repo.recordHistory(album: album, chapter: chapters[3],
                                 positionMs: 0, durationMs: 1_500_000)

        let after = try XCTUnwrap(allHistory(ctx).first)
        XCTAssertEqual(after.chapterIdx, 4, "历史章号应更新为用户点的那章（章号值语义）")
        XCTAssertEqual(after.positionMs, 0, "历史位置应更新为本章起点")
        XCTAssertGreaterThan(after.updatedAt, 300,
                             "非静默写入必须把 updatedAt 顶新（LWW 判据才会翻成本地较新）")
    }

    // MARK: - build 55 · P1-2 通道 ②（deinit；通道 ① pause / ③ periodic
    // 见无容器类 Build55HistoryGateTests，拆形原因见类头注释）

    /// 通道 ②：`deinit`（末行调 `pause()`）。b54 里它同样不受 silentWrite 约束。
    ///
    /// 取证口径说明（如实标注）：落库走 `Task { [weak self] in await self?.drain… }`，
    /// 而 deinit 期间对**正在析构对象**的 weak 引用立即解引用为 nil——排水任务不会
    /// 执行，所以「recorder 零调用」在修复前后都成立，不能作为本通道的证据。
    /// 因此在闸门处加了同步探针 `onSuppressedHistoryWriteForTesting`：
    /// 真构造一个静默装载过的 PM、真让它离开作用域触发 deinit，同步取证「闸门确实拦到了」。
    /// 反向对照：不加 silentWrite 的 PM 析构时闸门**不触发**（该写会照常入队）。
    @MainActor
    func testDeinitChannelIsGatedBySilentPending() async throws {
        let suppressed = HitCounter()
        do {
            let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5416)
            let chapters = oneBasedChapters(8, durationSec: 1_200)
            let pm = PlaybackManager(playbackRepository: nil)
            pm.onSuppressedHistoryWriteForTesting = { suppressed.bump() }
            pm.prepareQueue(album: album, chapters: chapters,
                            start: .arrayPosition(2), startPosMs: 100_000, silentWrite: true)
            XCTAssertTrue(pm.historyWriteSuppressed)
            // 作用域结束 → deinit → 末行 pause() → recordHistory(force: true)
        }
        XCTAssertEqual(suppressed.hits, 1,
                       "静默装载未收听就退页：deinit 通道必须被闸门拦住（b54 会落一条旧历史）")

        // 反向对照：非静默装载的 PM 析构 → 闸门不拦（该写入照常入队）
        let released = HitCounter()
        do {
            let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5417)
            let chapters = oneBasedChapters(8, durationSec: 1_200)
            let pm = PlaybackManager(playbackRepository: nil)
            pm.onSuppressedHistoryWriteForTesting = { released.bump() }
            pm.prepareQueue(album: album, chapters: chapters, startIdx: 1)
            XCTAssertFalse(pm.historyWriteSuppressed)
        }
        XCTAssertEqual(released.hits, 0, "非静默装载的析构不得被闸门拦截（对照：闸门不是常闭）")
    }

    // MARK: - 接线守卫（非行为级，如实标注）

    /// AlbumScreen 必须消费 planner 结论并以 `.arrayPosition` 语义静默装载
    /// （`autoPlay:false` 由 prepareQueue 保证）。UI 滚动 / 生命周期在单测沙箱
    /// 无法真跑，此用例只做接线形态守卫——真机行为由交付报告如实列为未验项。
    func testAlbumScreenConsumesPlannerSilently() throws {
        let src = try Self.source("TingYou/UI/Album/AlbumScreen.swift")
        XCTAssertTrue(src.contains("OpenResumePlanner.plan("), "AlbumScreen 必须经 planner 产出定位结论")
        XCTAssertTrue(src.contains("start: .arrayPosition(plan.arrayPosition)"),
                      "装载必须走数组位置语义（不得回退到按章号值猜测）")
        XCTAssertTrue(src.contains("startPosMs: plan.startPosMs"), "装载必须带历史位置")
        XCTAssertTrue(src.contains("proxy.scrollTo(plan.chapter.chapterId"),
                      "章节列表必须滚动到历史章（需求 e 打开即到位）")
        XCTAssertTrue(src.contains("didScrollToCurrent"), "定位只做一次（切章不抢滚动）")
        XCTAssertTrue(src.contains("silentWrite: true"),
                      "定位装载不得写历史（否则打开详情页即把 updatedAt 顶成现在，"
                      + "LWW 判定翻成本地较新 → 跨端续播回退）")
    }

    /// 书架 / 启动恢复链路必须同样走 `.arrayPosition`（1 基源早一章缺陷的修复点）。
    func testRestorePathsUseArrayPositionSemantics() throws {
        let shelf = try Self.source("TingYou/UI/Shelf/ShelfScreen.swift")
        let content = try Self.source("TingYou/UI/ContentView.swift")
        XCTAssertTrue(shelf.contains("startArrayPosition: startIdx"),
                      "书架恢复必须按 planner 输出的数组位置装载")
        XCTAssertTrue(content.contains("start: .arrayPosition(startIdx)"),
                      "启动恢复必须按 planner 输出的数组位置装载")
        XCTAssertTrue(content.contains("silentWrite: true"),
                      "启动恢复不得写历史（否则 updatedAt 被顶成现在，云端较新进度被拒合并）")
    }

    // MARK: - 云端桩（与 b53 同构）

    @MainActor
    private func makeEngine(modelContext: ModelContext?) -> SyncEngine {
        let client = SyncCloudClient(session: RetryStubURLProtocol.makeSession())
        return SyncEngine(client: client, store: store, modelContext: modelContext)
    }

    private func login(accessExpiresInMs: Int64) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        store.saveCredentials(SyncLocalStore.Credentials(
            accessToken: "atk-b54", refreshToken: "rtk-b54", userId: "u1",
            email: "b54@test.mail", deviceId: "d1",
            accessExpireAtMs: now + accessExpiresInMs,
            refreshExpireAtMs: now + 30 * 24 * 3600 * 1000))
    }

    private static func path(_ req: URLRequest) -> String {
        guard let url = req.url else { return "" }
        return url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
    }

    private static func ok(_ dataJSON: String) -> (Int, Data) {
        (200, Data(#"{"code":0,"message":"ok","data":\#(dataJSON)}"#.utf8))
    }

    private static func err(_ code: Int, _ message: String) -> (Int, Data) {
        (200, Data(#"{"code":\#(code),"message":"\#(message)","data":null}"#.utf8))
    }

    private static func pullJSON(serverSeq: Int64, favorites: [[String: Any]],
                                 progress: [[String: Any]]) -> String {
        #"{"server_seq":\#(serverSeq),"since_seq":0,"snapshot_required":false,"favorites":\#(jsonArray(favorites)),"progress":\#(jsonArray(progress))}"#
    }

    private static func jsonArray(_ rows: [[String: Any]]) -> String {
        guard !rows.isEmpty else { return "[]" }
        let parts = rows.map { row -> String in
            let body = row.keys.sorted().map { key -> String in
                let v = row[key]!
                if let s = v as? String { return #""\#(key)":"\#(s)""# }
                return #""\#(key)":\#(v)"#
            }.joined(separator: ",")
            return "{\(body)}"
        }
        return "[\(parts.joined(separator: ","))]"
    }

    // MARK: - 源码读取（崩溃安全：XCTFail + throw，不用 fatalError）

    private static func source(_ rel: String) throws -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("\(rel) 不存在：\(path)——路径布局变化时请同步修正本测试")
            throw NSError(domain: "Build54FeatureTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing source \(rel)"])
        }
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(rel) 不可读：\(path)")
            throw NSError(domain: "Build54FeatureTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "unreadable source \(rel)"])
        }
        return src
    }
}
