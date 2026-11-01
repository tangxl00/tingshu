import XCTest
@testable import TingYou

/// build 56 · P1-B 第四轮（阶梯诊断 · bisect ladder）。
///
/// ## 前三轮取证结论（CI 实证，非推测）
///
/// 四条闸门用例在 b55 / b56-r1 / b56-r2 / b56-r3 四种形态下全部 0.000s 进程级崩溃：
/// * b55 基线（fb1c0031）：无 setUp、非 @MainActor、纯探针、三条用例——崩；
/// * r1：+ T4 镜像用例——崩；
/// * r2（f9bf9316）：@MainActor——崩；
/// * r3（d738fbdf）：补 Build54 同款 setUp（内存 ModelContainer + SyncLocalStore）
///   + 真实 AlbumRepository fanout + DB 行级断言——仍崩，且崩溃后会话整体中止
///   （exit 65，r1/r2 则逐条重启复崩）。
///
/// 已证伪假说：容器有无 / @MainActor / 真 repo fanout / NSLock async 告警 /
/// 宿主级 try!（AppContainer 已修）/ 前置投毒类 / recordHistory→drain→recorder
/// 全链（SkipSettings 通过用例走同一链含真写）。与同进程通过的
/// `SkipSettingsTests.testPrepareQueueRecordsIntroSkippedStartPosition`
/// 的结构性差异已收敛到：章表数据 / prepareQueue 主形态 vs legacy 重载 /
/// 断言目标 / 默认 skipStore。
///
/// ## 本轮做法：在类内、四条原始用例之前插入 testA0–testA6 阶梯哨兵
///
/// 每级是 T1 序列的递进前缀（字母序保证先于四条原始用例执行）：
/// A0 空用例 → A1 仅构造 PM → A2 +recorder → A3 +prepareQueue → A4 +等排水
/// → A5 完整 T1 形态（@MainActor + 断言）→ A6 SkipSettings 通过用例的同款拷贝
/// （在本类语境下复跑一份已被历轮 CI 验证必绿的用例体）。
///
/// 判读口径（CI 铁律）：单元测试的断言消息与 print 均不落 test.log，唯一可靠
/// 信号 = `Test case … passed/failed` 行 + 时长（0.000s failed = 进程崩溃）。
/// 崩在哪一级，崩点就在该级新增的代码层；A6 若在本类崩而在 SkipSettingsTests
/// 绿，则为类语境/执行环境问题而非用例体问题。
///
/// 四条原始用例（b55 复检评审口径）**逐字保留**：未删、未 @skip、未弱化断言。
/// r3 曾附加的 DB 行级断言撤回（归 Build54FeatureTests 已通过的无 PM 直调用例
/// `testApplyPlanLoadsHistoricalChapterSilently` / `testNonSilentRepoWriteBumpsUpdatedAt`
/// 承担，证据链不缺环）——本轮目标是定位并消除进程崩溃，使四条原始用例真实跑绿。
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

    // MARK: - r4 阶梯哨兵（字母序先于四条原始用例执行；判读见类头）

    /// A0：空用例。若本条也 0.000s 崩溃 → 崩点在类装载/发现/环境层，
    /// 与任何用例体无关（本类无 setUp，无任何前置代码）。
    func testA0EmptyCanary() {
        XCTAssertTrue(true, "A0 空哨兵")
    }

    /// A1：仅构造 PM（init 全链：AudioSession/NowPlaying/周期观察器/通知订阅）
    /// 并让其离开作用域触发 deinit。新增层 = PM init + deinit。
    func testA1ConstructPMCanary() {
        do {
            let pm = PlaybackManager(playbackRepository: nil)
            XCTAssertFalse(pm.historyWriteSuppressed, "新构造的 PM 不得处于抑制态")
        }
    }

    /// A2：A1 + 探针注入（不装载任何章节）。新增层 = historyRecorder 赋值。
    func testA2RecorderCanary() {
        do {
            let recorder = ProbeHistoryRecorder()
            let pm = PlaybackManager(playbackRepository: nil)
            pm.historyRecorder = recorder
            XCTAssertEqual(recorder.writes.count, 0, "未装载不得有写")
        }
    }

    /// A3：A2 + 非静默装载主形态（不等排水、不断言写发生——避免 A4 层混淆）。
    /// 新增层 = prepareQueue 主形态（含 loadCurrentChapter nil-repo 早退 +
    /// recordHistory(force:) 入队）。
    func testA3PrepareQueueCanary() {
        do {
            let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5414)
            let chapters = oneBasedChapters(15, durationSec: 1_500)
            let recorder = ProbeHistoryRecorder()
            let pm = PlaybackManager(playbackRepository: nil)
            pm.historyRecorder = recorder
            pm.prepareQueue(album: album, chapters: chapters,
                            start: .indexValue(4), startPosMs: 0, silentWrite: false)
            XCTAssertFalse(pm.historyWriteSuppressed, "非静默装载不得进入抑制态")
        }
    }

    /// A4：A3 + 等待历史排水完成。新增层 = waitForHistoryIdle 轮询 + 排水任务
    /// （Task → drainHistoryQueue → 探针真写）。
    func testA4PrepareAndWaitCanary() async throws {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5414)
        let chapters = oneBasedChapters(15, durationSec: 1_500)
        let recorder = ProbeHistoryRecorder()
        let pm = PlaybackManager(playbackRepository: nil)
        pm.historyRecorder = recorder
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .indexValue(4), startPosMs: 0, silentWrite: false)
        XCTAssertFalse(pm.historyWriteSuppressed, "非静默装载不得进入抑制态")
        try await waitForHistoryIdle(pm)
    }

    /// A5：完整 T1 形态（@MainActor + 写断言）。与 testNonSilentLoad…
    /// 同体；若 A4 绿而本条崩，差分 = @MainActor 标注 + 写断言。
    @MainActor
    func testA5FullT1ShapeCanary() async throws {
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

    /// A6：SkipSettings 通过用例的同款拷贝（`testPrepareQueueRecordsIntroSkipped
    /// StartPosition` 逐字复刻，仅换独立 suite 名）。该用例体在 SkipSettingsTests
    /// 里历轮 CI 全绿；若同一份代码在本类语境下崩 → 崩点不在用例体，而在
    /// 类语境/执行环境（类名、发现顺序、克隆分配等）。
    func testA6SkipSettingsShapeCanary() async throws {
        let defaults = UserDefaults(suiteName: "Build55GateCanary-\(UUID().uuidString)")!
        let store = SkipSettingsStore(defaults: defaults)
        store.setIntro(30, src: "tingyou", albumId: 501)

        let recorder = ProbeHistoryRecorder()
        let pm = PlaybackManager(playbackRepository: nil, skipStore: store)
        pm.historyRecorder = recorder
        let album = Album(albumId: 501, title: "跳过测试书", author: nil, teller: nil,
                          coverUrl: nil, intro: nil, category: nil, categoryId: nil,
                          type: nil, typeId: nil, status: nil, chapterCount: nil,
                          updatedAt: nil, playCount: nil, available: nil,
                          source: "tingyou", detailPath: nil)
        let chapters = [
            Chapter(chapterId: 1, index: 0, title: "第01集", durationSec: 1800),
            Chapter(chapterId: 2, index: 1, title: "第02集", durationSec: 1750),
            Chapter(chapterId: 3, index: 2, title: "第03集", durationSec: 1600),
        ]
        pm.playQueue(album: album, chapters: chapters, startIdx: 0)

        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.first?.positionMs, 30_000,
                       "起播历史位置应为片头跳过后的 30s，而非 0")
        // 等排水后 PM 处于播放态，测试收尾暂停结算
        pm.pause()
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
    /// 「updatedAt 不被顶」的 DB 行级证据由 `testApplyPlanLoadsHistoricalChapterSilently`
    /// （静默装载侧）承担；本条守重建通道行为。
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
