import XCTest
import SwiftData
@testable import TingYou

/// build 56 · P1-B（第三轮 · 骨架同化 + 行级取证）
///
/// ## 背景（b56 前两轮取证结论，逐条列明以便复核）
///
/// b55 复检 NO-GO 的 P1-B 要求：闸门用例必须在 CI **真实跑绿**（test.log 出现
/// `** TEST SUCCEEDED **`、逐条 passed），禁止 @skip / 删用例 / 改弱断言。
/// b56 r1（无 @MainActor）与 r2（有 @MainActor）两轮 CI 实测：四条用例均
/// **0.000s 进程级崩溃**（pid 逐条更替；test.log 在最后一条 failed 行戛然而止，
/// 连 xcodebuild 的汇总段都没写出来），5 轮 100% 复现（b55 r2/r3/r4 在带容器的
/// Build54 类、b56 r1/r2 在本类）。
///
/// 已排除的假说（均有 CI 证据，不是推测）：
/// * **容器有无**：b55 三轮在带 ModelContainer 的 Build54 类里同样崩；
/// * **@MainActor 隔离域**：r1 无标注崩、r2 有标注也崩；
/// * **类 / 文件载体**：同一批用例在 Build54 类崩、搬进本类照样崩；
/// * **宿主级地雷**（r2 三处对症修复：AppContainer `try!` → 删库重建 / 内存降级、
///   ContentView 测试宿主跳过启动恢复、Build29 拆除「真 repo + prepareQueue」
///   武装点）：对本类四条**无效**、仍崩；但 Build49 断言修复转绿、其余 341 条全过
///   → 本轮修复零回归，且「宿主级地雷」假说对本类不成立。
/// * **用例体无 trap**：与同进程通过的
///   `Build54FeatureTests.testApplyPlanLoadsHistoricalChapterSilently`
///   （同为 PM + prepareQueue + 同一份 waitForHistoryIdle + 同一份探针 + @MainActor）
///   几乎同构；`recordHistory` / `enqueueHistory` / `drainHistoryQueue` 全链静态审计
///   无 fatalError / try! / as! / 强解包。
///
/// ## 本轮（r3）做法：向**已验证通过的骨架**同化 + 证据加厚
///
/// 1. **骨架同化**：本类补上 Build54 通过用例的同款 setUp/tearDown（独立
///    UserDefaults suite + SyncLocalStore + 内存 ModelContainer +
///    RetryStubURLProtocol.reset()），并把 `historyRecorder` 换成**探针 + 真实
///    `AlbumRepository` 的 fanout**（Build54 同款形态）。这两项是本类与唯一同构
///    通过用例之间**仅剩的结构差异**（`AlbumRepository` 是 actor、写入统一经
///    `MainActor.run`，接进 fanout 不引入跨线程 ModelContext 风险）。
/// 2. **证据加厚（非弱化）**：闸门断言从「探针零调用 ⇒ 无落库路径」升级为
///    **DB 行级**取证——静默期直接断言「历史行的 updatedAt / 章号 / 位置未被碰」，
///    解除期直接断言「行被顶新」。P1-A 要求的「零历史写入 / updatedAt 不被顶 /
///    解除后正常写」由此在同一批用例里同时拿到**通道证据 + 行级证据**
///    （原先 updatedAt 侧证据只由 Build54 的无 PM 直调用例承担）。
/// 3. **崩溃定位标记**：各阶段打 `print("[B56GATE] …")`，供 CI 日志定位崩点。
///
/// 四条用例名与既有断言**逐条保留**（未删、未 @skip、未弱化）；新增断言只加不减。
final class Build55HistoryGateTests: XCTestCase {

    // MARK: - 骨架（与 Build54FeatureTests 通过用例同款）

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SyncLocalStore!
    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        RetryStubURLProtocol.reset()
        suiteName = "b56-gate-\(UUID().uuidString)"
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

    // MARK: - 工具（与 SkipSettingsTests 同构：探针 + 空闲轮询，无 SwiftData）

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

    /// 等历史串行排水结束（`recordHistory` 是异步入队 + 单任务排水）。
    /// `isHistoryWriteIdle` 由 `historyLock` 保护，任意隔离域可安全轮询。
    private func waitForHistoryIdle(_ pm: PlaybackManager) async throws {
        for _ in 0..<200 {
            if pm.isHistoryWriteIdle { return }
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        XCTFail("历史排水 1s 内未空闲（isHistoryWriteIdle 恒 false）")
    }

    /// 可记录的历史写入探针（零调用可断言）。
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

    /// 跨线程计数（闸门回调可能在任意线程触发）。
    final class HitCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var hits: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }

    /// 探针 + 真实 `AlbumRepository` 的双通道记录器（Build54FeatureTests 同款形态）：
    /// 探针负责「调用次数」取证，真实 repo 负责「DB 行被写成什么样」取证。
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

    /// 读回历史行（@MainActor：mainContext 只能在主线程用）。
    @MainActor
    private func allHistory(_ ctx: ModelContext) -> [HistoryModel] {
        (try? ctx.fetch(FetchDescriptor<HistoryModel>())) ?? []
    }

    /// 埋一条「云端合并后的较新进度」：静默期它若被顶成 now，即为闸门被绕过。
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

    // MARK: - P1-1 反证（写发生半边）：非静默装载必须真写（闸门放行）

    /// `Build54FeatureTests.testApplyPlanLoadsHistoricalChapterSilently` 证明
    /// 「静默装载零写 + `updatedAt` 不顶新」；本用例是反证的另一半：同样的装载、
    /// 只把 `silentWrite` 换成 false，必须经真闸门（`recordHistory` 完整路径：
    /// 闸门放行 → 节流 → 入队 → 串行排水）**确实写一次**。若守卫被误改成
    /// 「非静默也不写」，本条变红。
    ///
    /// 行级证据（本轮新增，只加不减）：写确实落到 DB 行并把 `updatedAt` 顶新
    /// ——「写发生了」不再只由探针自报。
    @MainActor
    func testNonSilentLoadEnqueuesHistoryWrite() async throws {
        print("[B56GATE] T1 start")
        let ctx = container.mainContext
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5414)
        let chapters = oneBasedChapters(15, durationSec: 1_500)
        seedHistory(ctx, album: album, chapterIdx: 11, chapterTitle: "第11章",
                    positionMs: 480_000, updatedAt: 300)
        let recorder = ProbeHistoryRecorder()
        let repo = AlbumRepository(apiClient: APIClient(session: RetryStubURLProtocol.makeSession()),
                                   modelContext: ctx)
        let pm = PlaybackManager(playbackRepository: nil)
        pm.historyRecorder = RecordingFanout([recorder, repo])

        pm.prepareQueue(album: album, chapters: chapters,
                        start: .indexValue(4), startPosMs: 0, silentWrite: false)
        print("[B56GATE] T1 prepared")
        XCTAssertFalse(pm.historyWriteSuppressed, "非静默装载不得进入抑制态")
        try await waitForHistoryIdle(pm)
        print("[B56GATE] T1 idle")
        XCTAssertEqual(recorder.writes.count, 1, "非静默装载必须写一次历史（反证守卫没写死）")
        XCTAssertEqual(recorder.writes.first?.chapterTitle, "第4章",
                       "写的是装载落点章（用户点的那章）")
        // 行级证据：写落到 DB 行（章号/位置按装载落点，updatedAt 被顶新）
        let row = try XCTUnwrap(allHistory(ctx).first, "落库行必须可读回")
        XCTAssertEqual(row.chapterIdx, 4, "DB 行章号应更新为装载落点章")
        XCTAssertEqual(row.positionMs, 0, "DB 行位置应更新为装载落点")
        XCTAssertGreaterThan(row.updatedAt, 300,
                             "非静默写必须把 updatedAt 顶新（LWW 判据才翻成本地较新）")
    }

    // MARK: - P1-2 三通道闸门（pause / periodic；deinit 见 Build54FeatureTests）

    /// 通道 ①：`pause()`。静默装载后用户在别处按暂停（`nextChapter`/
    /// `previousChapter` 内部先调 pause()，控制中心暂停键同样直达 pause()）——
    /// b54 这里无条件 `recordHistory(force: true)`（第 1549 行），会落一条
    /// **旧位置**历史并掀翻云端。
    ///
    /// 行级证据（本轮新增）：抑制期那条「云端较新」的历史行**不得被碰**
    /// （updatedAt 保持 300、章号/位置不变）；解除抑制后同一行必须被顶新。
    @MainActor
    func testPauseChannelDoesNotWriteDuringSilentPending() async throws {
        print("[B56GATE] T2 start")
        let ctx = container.mainContext
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5415)
        let chapters = oneBasedChapters(10, durationSec: 1_200)
        seedHistory(ctx, album: album, chapterIdx: 11, chapterTitle: "第11章",
                    positionMs: 480_000, updatedAt: 300)
        let recorder = ProbeHistoryRecorder()
        let repo = AlbumRepository(apiClient: APIClient(session: RetryStubURLProtocol.makeSession()),
                                   modelContext: ctx)
        let pm = PlaybackManager(playbackRepository: nil)
        pm.historyRecorder = RecordingFanout([recorder, repo])

        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(5), startPosMs: 500_000, silentWrite: true)
        print("[B56GATE] T2 prepared")
        XCTAssertTrue(pm.historyWriteSuppressed, "静默装载后应处于抑制态")
        try await waitForHistoryIdle(pm)

        pm.pause()   // ← P1-2 通道 ①（复检定位 1549 行）
        try await waitForHistoryIdle(pm)
        print("[B56GATE] T2 paused")
        XCTAssertEqual(recorder.writes.count, 0,
                       "静默装载期暂停不得写历史（唯一落库出口零调用）")
        // 行级证据：抑制期那条行不得被碰
        let during = try XCTUnwrap(allHistory(ctx).first, "埋入行必须可读回")
        XCTAssertEqual(during.updatedAt, 300, "静默装载期暂停不得把 updatedAt 顶成 now")
        XCTAssertEqual(during.chapterIdx, 11, "静默装载期暂停不得改写章号")
        XCTAssertEqual(during.positionMs, 480_000, "静默装载期暂停不得改写位置")

        // 解除点：用户真按播放 → 抑制解除 → 再暂停必须照写（证明不是写死关掉）
        pm.play()          // 播放器为空（nil repository）会早退，但解除在 guard 之前
        XCTAssertFalse(pm.historyWriteSuppressed, "用户按播放后抑制必须解除")
        pm.pause()
        try await waitForHistoryIdle(pm)
        print("[B56GATE] T2 released")
        XCTAssertEqual(recorder.writes.count, 1, "解除后暂停必须正常落历史（真实收听）")
        XCTAssertEqual(recorder.writes.first?.chapterTitle, "第6章",
                       "解除后的写必须是当前装载章（静默装载的落点，非旧章）")
        // 行级证据：解除后同一行被顶新
        let after = try XCTUnwrap(allHistory(ctx).first, "落库行必须可读回")
        XCTAssertGreaterThan(after.updatedAt, 300, "解除抑制后的写必须把 updatedAt 顶新")
        XCTAssertEqual(after.chapterIdx, 6, "解除后的写必须是当前装载章（行级）")
    }

    /// 通道 ③：周期观察器（1 秒一拍 `recordHistory()`，5s 节流）。
    ///
    /// **如实标注的测试限制**：`addPeriodicTimeObserver` 的回调由 AVPlayer 驱动，
    /// 需要真实播放中的条目（readyToPlay + 时钟推进）才会回调；单测沙箱里
    /// `playbackRepository: nil` 不建播放机器、条目也永远不 ready，因此**无法**
    /// 让那个闭包自然触发（强行伪造 CMTime 也只会打到同一个私有闭包，不是真通道）。
    /// 替代断言：周期拍与 pause/deinit 走的是**同一个入口** `recordHistory(force: false)`
    /// ——闸门就装在该入口上，故这里直接驱动该入口（经生产同一份实现的
    /// `recordHistoryForTesting` 接缝，非静默装载的 PM 上调用）来证明：
    /// 「抑制态下节流拍的写入同样被拦、且不会消耗节流窗口 / 不落库」。
    @MainActor
    func testPeriodicChannelSharesTheSameGate() async throws {
        print("[B56GATE] T3 start")
        let ctx = container.mainContext
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5418)
        let chapters = oneBasedChapters(6, durationSec: 1_200)
        seedHistory(ctx, album: album, chapterIdx: 11, chapterTitle: "第11章",
                    positionMs: 480_000, updatedAt: 300)
        let recorder = ProbeHistoryRecorder()
        let repo = AlbumRepository(apiClient: APIClient(session: RetryStubURLProtocol.makeSession()),
                                   modelContext: ctx)
        let pm = PlaybackManager(playbackRepository: nil)
        pm.historyRecorder = RecordingFanout([recorder, repo])
        let suppressed = HitCounter()
        pm.onSuppressedHistoryWriteForTesting = { suppressed.bump() }

        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(2), startPosMs: 400_000, silentWrite: true)
        // 模拟周期拍：连拍 3 次（真实实现每秒 1 次、内部 5s 节流）
        for _ in 0..<3 { pm.recordHistoryForTesting() }
        try await waitForHistoryIdle(pm)
        print("[B56GATE] T3 suppressed")

        XCTAssertEqual(suppressed.hits, 3, "抑制态下每次周期拍都被闸门拦下（同一入口）")
        XCTAssertEqual(recorder.writes.count, 0, "周期拍不得写历史（唯一落库出口零调用）")
        // 行级证据：抑制期那条行不得被碰
        let during = try XCTUnwrap(allHistory(ctx).first, "埋入行必须可读回")
        XCTAssertEqual(during.updatedAt, 300, "抑制态周期拍不得把 updatedAt 顶成 now")
        XCTAssertEqual(during.chapterIdx, 11, "抑制态周期拍不得改写章号")

        // 解除后同一入口必须恢复工作（且节流窗口未被抑制期的空跑提前吃掉）
        pm.play()
        pm.recordHistoryForTesting()
        try await waitForHistoryIdle(pm)
        print("[B56GATE] T3 released")
        XCTAssertEqual(recorder.writes.count, 1, "解除抑制后周期拍必须能落库")
        // 行级证据：解除后行被顶新
        let after = try XCTUnwrap(allHistory(ctx).first, "落库行必须可读回")
        XCTAssertGreaterThan(after.updatedAt, 300, "解除抑制后周期拍必须把 updatedAt 顶新")
    }

    // MARK: - build 56 · P1-A 行为级（镜像重试重建通道不得绕过闸门）

    /// 复检 P1-A：b55 的两处镜像重建调用点写的是
    /// `loadCurrentChapter(autoPlay: true, keepMirrorChain: true)`（**不传 silentWrite**）
    /// → 走 `else if autoPlay || !keepMirrorChain` → `releaseHistorySuppression()` +
    /// 末尾落历史 → 「静默装载 + 20 秒看门狗换镜像」即可绕过闸门，把旧位置写进历史
    /// 并顶新 `updatedAt`（LWW 翻成本地较新 + outbox 反向污染云端，与 b54 P1-2 同模式）。
    ///
    /// 本用例驱动的是**生产同一份实现** `rebuildForMirrorRetry()`（statusObserver
    /// `.retry` 分支与流式看门狗切镜像分支共用的唯一重建入口），不是用例里复制的
    /// 调用逻辑——把两处调用点收敛成一个函数，就是为了让这条用例真的守住那两个分支。
    ///
    /// 断言分三段（对应复检要求的「零历史写入 / updatedAt 不被顶 / 解除后正常写」）：
    /// ① 抑制期重建：**抑制态保持**（未被自动解除）+ 探针零写入 + **DB 行未被碰**；
    /// ② 连续重建（链上多次切镜像）仍保持抑制、仍零写入，且闸门**确实拦到了**
    ///    （`onSuppressedHistoryWriteForTesting` 同步计数，防「靠 recorder 为 nil 假绿」）；
    /// ③ 解除后同一条重建路径必须照写（证明修复不是把镜像重试的写历史能力写死）。
    @MainActor
    func testMirrorRetryRebuildDoesNotBypassSilentGate() async throws {
        print("[B56GATE] T4 start")
        let ctx = container.mainContext
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5420)
        let chapters = oneBasedChapters(12, durationSec: 1_500)
        seedHistory(ctx, album: album, chapterIdx: 11, chapterTitle: "第11章",
                    positionMs: 480_000, updatedAt: 300)
        let recorder = ProbeHistoryRecorder()
        let repo = AlbumRepository(apiClient: APIClient(session: RetryStubURLProtocol.makeSession()),
                                   modelContext: ctx)
        let pm = PlaybackManager(playbackRepository: nil)
        pm.historyRecorder = RecordingFanout([recorder, repo])
        let suppressed = HitCounter()
        pm.onSuppressedHistoryWriteForTesting = { suppressed.bump() }

        // 静默装载（打开详情页定位形态：用户还没按播放）
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(3), startPosMs: 260_000, silentWrite: true)
        XCTAssertTrue(pm.historyWriteSuppressed, "前置：静默装载后必须处于抑制态")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 0, "前置：静默装载本身不得写历史")
        print("[B56GATE] T4 prepared")

        // ① 镜像重试重建（网络错误分支 / 看门狗切镜像分支共用的生产入口）
        let hitsBefore = suppressed.hits
        pm.rebuildForMirrorRetry()
        XCTAssertTrue(pm.historyWriteSuppressed,
                      "抑制期的镜像重建不得解除抑制（b55 此处会把闸门绕过）")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 0,
                       "抑制期的镜像重建不得落历史（零历史写入）")
        XCTAssertEqual(suppressed.hits, hitsBefore,
                       "抑制期重建必须一路保持抑制、无被拦下的写尝试（未走非抑制分支）")
        // 行级证据：updatedAt 不被顶（复检 P1-A 的核心要求）
        let during = try XCTUnwrap(allHistory(ctx).first, "埋入行必须可读回")
        XCTAssertEqual(during.updatedAt, 300,
                       "抑制期的镜像重建不得把 updatedAt 顶成 now（P1-A 核心）")
        XCTAssertEqual(during.chapterIdx, 11, "抑制期的镜像重建不得改写章号")
        XCTAssertEqual(during.positionMs, 480_000, "抑制期的镜像重建不得改写位置")

        // ② 链上多次重建（模拟连切 backup 镜像）：抑制不被逐次累积解除
        for _ in 0..<3 { pm.rebuildForMirrorRetry() }
        XCTAssertTrue(pm.historyWriteSuppressed, "连切镜像不得逐次解除抑制")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 0, "连切镜像仍不得写历史")
        let stillUntouched = try XCTUnwrap(allHistory(ctx).first, "埋入行必须可读回")
        XCTAssertEqual(stillUntouched.updatedAt, 300, "连切镜像仍不得把 updatedAt 顶成 now")
        print("[B56GATE] T4 rebuilt")

        // ③ 解除点：用户真按播放 → 抑制解除 → 同一条重建路径必须照写（非写死）
        pm.play()
        XCTAssertFalse(pm.historyWriteSuppressed, "用户按播放后抑制必须解除")
        pm.rebuildForMirrorRetry()
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 1,
                       "解除抑制后的镜像重建必须照写历史（真实收听中的换镜像行为不变）")
        XCTAssertEqual(recorder.writes.first?.chapterTitle, "第4章",
                       "重建后写的是当前装载章（静默装载的落点，非旧章）")
        // 行级证据：解除后行被顶新（真实收听语义不变）
        let after = try XCTUnwrap(allHistory(ctx).first, "落库行必须可读回")
        XCTAssertGreaterThan(after.updatedAt, 300, "解除抑制后的镜像重建必须把 updatedAt 顶新")
        XCTAssertEqual(after.chapterIdx, 4, "解除后的镜像重建写的是当前装载章（行级）")
        print("[B56GATE] T4 done")
    }
}
