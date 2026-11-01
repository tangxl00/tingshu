import XCTest
@testable import TingYou

/// build 55 · P1-1 反证（写发生半边）+ P1-2 三通道闸门（pause / periodic）的
/// **行为级**用例——无 SwiftData 形态（与 SkipSettingsTests 同构）。
///
/// ## build 56 · P1-B（崩溃根因更正 · 二轮）
///
/// b56 首轮把 CI 0.000s 崩溃定性为「用例缺 @MainActor 隔离域」并给四条用例
/// 加了标注——**该假设被同轮 CI 证伪**：加标注后四条仍 0.000s 崩，且 test.log
/// 里四条**全部缺失 "Test case … started" 行**（对照通过的用例均有 started +
/// 耗时），说明崩溃发生在用例体执行之前，与隔离域无关。
/// 二轮取证把证据重新对齐为三层：
/// * **不锁定本类**：b55 复检轮 Build54 的 `testPausedForeignQueueIsNotTornDown`
///   也出现第 3 轮崩 / 第 4 轮过的漂移分布——崩溃是进程级地雷，落点随机；
/// * **用例体无 trap**：与同进程通过的
///   `Build54FeatureTests.testApplyPlanLoadsHistoricalChapterSilently`（同为
///   静默装载 + 探针 + waitForHistoryIdle）几乎同构；`recordHistory`/
///   `enqueueHistory`/`drainHistoryQueue` 全链静态审计无 fatalError/
///   precondition/try!/as!；
/// * **「重启即崩」是确定性部分**：首崩后每个新 pid 都只活一条用例即死。
/// 收敛出的机制：长寿单测宿主（App 本体）进程撞随机地雷首崩 → 磁盘 SwiftData
/// store 半写 → 每次冷启动 `try! ModelContainer` 读损坏库直接 fatalError
/// （正是「0.000s / 无 started / pid 逐条更替」的死循环形态）。本版三处对症
/// 修复（守卫用例在 Build29RegressionTests）：
/// ① `AppContainer`：`try!` → 删库重建 / 内存降级（消除「重启即崩」）；
/// ② `Build29RegressionTests` 签名用例：拆除全测试目标唯一「真 repo +
///    prepareQueue」武装点（消除长寿进程随机地雷主嫌，b36 事故类）；
/// ③ `ContentView`：单测宿主跳过启动恢复（防磁盘历史在测试进程武装
///    AV 播放机器）。
/// 本类四条用例断言保持 build 55 原样（禁 @skip / 禁删用例 / 禁弱化断言）。
///
/// DB 行侧证据（updatedAt 顶新 / 静默不顶新）仍由 Build54FeatureTests 里
/// **无 PM** 的直调用例承担（`testNonSilentRepoWriteBumpsUpdatedAt` /
/// `testApplyPlanLoadsHistoricalChapterSilently`）。
///
/// 取证口径说明（如实标注）：本类断言全部经**生产出口**观测——`historyRecorder`
/// 是 `recordHistory` 唯一的落库出口（生产由 AppContainer 注入
/// AlbumRepository），探针零调用 ⇒ 不存在任何落库路径；「写发生后 DB 行确实
/// 顶新」由上述直调用例补齐，两半共同覆盖复检 P1-1/P1-2 的行为级要求。
final class Build55HistoryGateTests: XCTestCase {

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

    // MARK: - P1-1 反证（写发生半边）：非静默装载必须真写（闸门放行）

    /// `Build54FeatureTests.testApplyPlanLoadsHistoricalChapterSilently` 证明
    /// 「静默装载零写 + `updatedAt` 不顶新」；本用例是反证的另一半：同样的装载、
    /// 只把 `silentWrite` 换成 false，必须经真闸门（`recordHistory` 完整路径：
    /// 闸门放行 → 节流 → 入队 → 串行排水）**确实写一次**。若守卫被误改成
    /// 「非静默也不写」，本条变红。「写发生后 updatedAt 顶新」的 DB 侧证据由
    /// `Build54FeatureTests.testNonSilentRepoWriteBumpsUpdatedAt`（直调生产 repo）
    /// 承担——两半拆开的工程原因见类头注释。
    @MainActor
    func testNonSilentLoadEnqueuesHistoryWrite() async throws {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5414)
        let chapters = oneBasedChapters(15, durationSec: 1_500)
        let recorder = ProbeHistoryRecorder()
        let pm = PlaybackManager(playbackRepository: nil)
        pm.historyRecorder = recorder

        pm.prepareQueue(album: album, chapters: chapters,
                        start: .indexValue(4), startPosMs: 0, silentWrite: false)
        XCTAssertFalse(pm.historyWriteSuppressed, "非静默装载不得进入抑制态")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 1, "非静默装载必须写一次历史（反证守卫没写死）")
        XCTAssertEqual(recorder.writes.first?.chapterTitle, "第4章",
                       "写的是装载落点章（用户点的那章）")
    }

    // MARK: - P1-2 三通道闸门（pause / periodic；deinit 见 Build54FeatureTests）

    /// 通道 ①：`pause()`。静默装载后用户在别处按暂停（`nextChapter`/
    /// `previousChapter` 内部先调 pause()，控制中心暂停键同样直达 pause()）——
    /// b54 这里无条件 `recordHistory(force: true)`（第 1549 行），会落一条
    /// **旧位置**历史并掀翻云端。
    ///
    /// 抑制期「DB 行不被碰」的口径（如实标注）：`historyRecorder` 是
    /// `recordHistory` 唯一落库出口，探针零调用 ⇒ 不存在任何落库路径可碰那行；
    /// 「静默装载本身不顶 updatedAt」另有 DB 行级断言
    /// （`testApplyPlanLoadsHistoricalChapterSilently`：updatedAt 保持 300、
    /// 章号/位置不被装载落点覆盖）。
    @MainActor
    func testPauseChannelDoesNotWriteDuringSilentPending() async throws {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5415)
        let chapters = oneBasedChapters(10, durationSec: 1_200)
        let recorder = ProbeHistoryRecorder()
        let pm = PlaybackManager(playbackRepository: nil)
        pm.historyRecorder = recorder

        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(5), startPosMs: 500_000, silentWrite: true)
        XCTAssertTrue(pm.historyWriteSuppressed, "静默装载后应处于抑制态")
        try await waitForHistoryIdle(pm)

        pm.pause()   // ← P1-2 通道 ①（复检定位 1549 行）
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 0,
                       "静默装载期暂停不得写历史（唯一落库出口零调用）")

        // 解除点：用户真按播放 → 抑制解除 → 再暂停必须照写（证明不是写死关掉）
        pm.play()          // 播放器为空（nil repository）会早退，但解除在 guard 之前
        XCTAssertFalse(pm.historyWriteSuppressed, "用户按播放后抑制必须解除")
        pm.pause()
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 1, "解除后暂停必须正常落历史（真实收听）")
        XCTAssertEqual(recorder.writes.first?.chapterTitle, "第6章",
                       "解除后的写必须是当前装载章（静默装载的落点，非旧章）")
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
    /// 抑制期 DB 行不被碰的口径同 PauseChannel（唯一出口零调用 + ApplyPlan 的
    /// DB 行级断言）。
    @MainActor
    func testPeriodicChannelSharesTheSameGate() async throws {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5418)
        let chapters = oneBasedChapters(6, durationSec: 1_200)
        let recorder = ProbeHistoryRecorder()
        let pm = PlaybackManager(playbackRepository: nil)
        pm.historyRecorder = recorder
        let suppressed = HitCounter()
        pm.onSuppressedHistoryWriteForTesting = { suppressed.bump() }

        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(2), startPosMs: 400_000, silentWrite: true)
        // 模拟周期拍：连拍 3 次（真实实现每秒 1 次、内部 5s 节流）
        for _ in 0..<3 { pm.recordHistoryForTesting() }
        try await waitForHistoryIdle(pm)

        XCTAssertEqual(suppressed.hits, 3, "抑制态下每次周期拍都被闸门拦下（同一入口）")
        XCTAssertEqual(recorder.writes.count, 0, "周期拍不得写历史（唯一落库出口零调用）")

        // 解除后同一入口必须恢复工作（且节流窗口未被抑制期的空跑提前吃掉）
        pm.play()
        pm.recordHistoryForTesting()
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 1, "解除抑制后周期拍必须能落库")
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
    /// ① 抑制期重建：**抑制态保持**（未被自动解除）+ 探针零写入；
    /// ② 连续重建（链上多次切镜像）仍保持抑制、仍零写入，且闸门**确实拦到了**
    ///    （`onSuppressedHistoryWriteForTesting` 同步计数，防「靠 recorder 为 nil 假绿」）；
    /// ③ 解除后同一条重建路径必须照写（证明修复不是把镜像重试的写历史能力写死）。
    @MainActor
    func testMirrorRetryRebuildDoesNotBypassSilentGate() async throws {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5420)
        let chapters = oneBasedChapters(12, durationSec: 1_500)
        let recorder = ProbeHistoryRecorder()
        let suppressed = HitCounter()
        let pm = PlaybackManager(playbackRepository: nil)
        pm.historyRecorder = recorder
        pm.onSuppressedHistoryWriteForTesting = { suppressed.bump() }

        // 静默装载（打开详情页定位形态：用户还没按播放）
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(3), startPosMs: 260_000, silentWrite: true)
        XCTAssertTrue(pm.historyWriteSuppressed, "前置：静默装载后必须处于抑制态")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 0, "前置：静默装载本身不得写历史")

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

        // ② 链上多次重建（模拟连切 backup 镜像）：抑制不被逐次累积解除
        for _ in 0..<3 { pm.rebuildForMirrorRetry() }
        XCTAssertTrue(pm.historyWriteSuppressed, "连切镜像不得逐次解除抑制")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 0, "连切镜像仍不得写历史")

        // ③ 解除点：用户真按播放 → 抑制解除 → 同一条重建路径必须照写（非写死）
        pm.play()
        XCTAssertFalse(pm.historyWriteSuppressed, "用户按播放后抑制必须解除")
        pm.rebuildForMirrorRetry()
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 1,
                       "解除抑制后的镜像重建必须照写历史（真实收听中的换镜像行为不变）")
        XCTAssertEqual(recorder.writes.first?.chapterTitle, "第4章",
                       "重建后写的是当前装载章（静默装载的落点，非旧章）")
    }
}
