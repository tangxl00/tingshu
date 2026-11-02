import XCTest
import Observation
@testable import TingYou

/// build 57 · b56 复检结转的三项 P2 改进点，逐项一条行为级用例 + 一条形态守卫。
///
/// 判别力口径（每条用例都做过「旧实现下必红」的形态核对，见各用例注释）：
/// * P2-1（deinit 注释与代码自相矛盾）：`listenStartMs` 未加 `@ObservationIgnored`；
/// * P2-2（镜像重建退回章首）：`rebuildForMirrorRetry()` 不传 `startPosMs`，取缺省 0；
/// * P2-3（章末不写历史）：`.stop` 分支只有 `isPlaying = false`。
///
/// 行为级用例一律驱动**生产同一份实现**（`rebuildForMirrorRetry()` /
/// `simulateChapterFinishedForTesting()` → `onChapterFinished()` / deinit 结算），
/// 不在用例里复制一份调用逻辑。静态守卫用声明级 needle 并先剔注释——删除说明注释
/// 里会写满被断言的标识符名，不剔就会自证。
final class Build57FeatureTests: XCTestCase {

    // MARK: - 工具（与 Build55HistoryGateTests 同构）

    /// 独立的跳过设置库（不落全局 `UserDefaults.standard`）。
    ///
    /// 为什么必须注入：`PlaybackManager` 的 `skipStore` 缺省读 `UserDefaults.standard`，
    /// 而同一模拟器克隆内的单测共享一份 defaults——`SkipSettingsTests` 会通过
    /// `pm.setIntroSkip(30)` 往**全局**写 `skip_intro_tingyou_<albumId>`。若本类用全局
    /// store，`chapterStartMs(startPosMs:introSec:)` 就会把装载落点抬到 30s，
    /// 位置类断言（260_000 / 480_000）随之失真。逐用例套一件独立 suite 即可隔离，
    /// 且与生产口径（读持久化跳过设置）保持一致。
    private func isolatedSkipStore() -> SkipSettingsStore {
        let suite = "Build57Feature-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("无法创建隔离 UserDefaults suite：\(suite)")
            return SkipSettingsStore()
        }
        return SkipSettingsStore(defaults: defaults)
    }

    private func makeAlbum(src: String, albumId: Int64, title: String = "测试书") -> Album {
        Album(albumId: albumId, title: title, author: nil, teller: nil,
              coverUrl: nil, intro: nil, category: nil, categoryId: nil,
              type: nil, typeId: nil, status: nil, chapterCount: nil,
              updatedAt: nil, playCount: nil, available: true,
              source: src, detailPath: nil)
    }

    private func oneBasedChapters(_ n: Int, durationSec: Int? = nil) -> [Chapter] {
        (1...n).map { Chapter(chapterId: Int64($0), index: $0,
                              title: "第\($0)章", durationSec: durationSec) }
    }

    /// 等历史串行排水结束（`recordHistory` 异步入队 + 单任务排水）。
    private func waitForHistoryIdle(_ pm: PlaybackManager) async throws {
        for _ in 0..<200 {
            if pm.isHistoryWriteIdle { return }
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        XCTFail("历史排水 1s 内未空闲（isHistoryWriteIdle 恒 false）")
    }

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

    final class HitCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var hits: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - P2-1 · deinit 对 listenStartMs 的清理不再触碰 observation

    /// 背景（复检原文）：deinit 注释自述「@Observable 属性在 deinit 中 mutation 会
    /// 触发 observation registrar」，据此拿掉了 `isPlaying` 置位，但同一个 deinit
    /// 仍对 `listenStartMs`（普通存储属性、未加 `@ObservationIgnored`）赋值——风险
    /// 类别同源，只收了一半。
    ///
    /// 行为级判据（旧实现必红）：`startListeningSessionForTesting` 置起点 →
    /// 对象离开作用域触发 deinit → deinit 走**生产同一份** `settleListeningSession()`
    /// 结算，`ListeningTimeStore` 累计必须增加。旧实现虽也结算，但清零是对
    /// 未豁免属性赋值。所以本用例同时守住「修法不得把结算一起删掉」——
    /// 也就是修完之后时长口径必须一字不差地还在。
    @MainActor
    func testDeinitStillSettlesListeningTimeAfterObservationIgnored() async throws {
        let before = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore()).listeningTotalMsForTesting
        do {
            let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
            pm.startListeningSessionForTesting(at: Self.nowMs() - 2_000)
        } // 作用域结束 → deinit → settleListeningSession()
        let after = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore()).listeningTotalMsForTesting
        XCTAssertGreaterThanOrEqual(after - before, 1_900,
                                    "deinit 必须保留收听时长结算（清零只是不再触发 observation，结算不得一并删掉）")
        XCTAssertLessThan(after - before, 600_000, "结算时长异常（起点/计时口径被改坏）")
    }

    /// 行为级：`pause()` 与 deinit 共用同一份结算实现，且**先结算后清零**——
    /// 暂停结算一次，随后的 deinit 不得再结算第二次（起点已置 0）。
    @MainActor
    func testPauseSettlesOnceAndDeinitDoesNotDoubleCount() async throws {
        var afterPause: Int64 = 0
        var before: Int64 = 0
        do {
            let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
            before = pm.listeningTotalMsForTesting
            pm.startListeningSessionForTesting(at: Self.nowMs() - 1_500)
            pm.pause()
            afterPause = pm.listeningTotalMsForTesting
        }
        XCTAssertGreaterThanOrEqual(afterPause - before, 1_400, "暂停必须结算本段收听时长")
        let afterDeinit = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore()).listeningTotalMsForTesting
        XCTAssertEqual(afterDeinit, afterPause,
                       "暂停已结算并清零起点，deinit 不得重复结算同一段（先结算后清零）")
    }

    /// 行为级（旧实现必红）：**直接取证** `listenStartMs` 的变更是否进入 observation registrar。
    ///
    /// 这才是 P2-1 缺陷的判别证据。复检原文的指控是「deinit 对 `@Observable` 存储属性
    /// 赋值会触发 registrar」。Observation 的语义是：读取即注册依赖，**同一 runloop 周期
    /// 内的变更**使该依赖失效并回调第一次 onChange（下一周期不再回调）。
    ///
    /// 所以旧实现（未加 `@ObservationIgnored`）下：读取属性 → 同周期内写属性 →
    /// onChange 必被回调**至少一次**；加了 `@ObservationIgnored` 后读取不注册 →
    /// 写属性不回调 → 零次。这就是判别点，且是对真宏展开行为的取证，
    /// 不是「源码里有没有这串字符」的文本扫描。
    ///
    /// 时序要点：读取与变更必须落在**同一个 runloop 周期**内、且变更在 apply 闭包**之后**。
    /// apply 闭包是同步执行的，闭包返回后立刻写属性即同周期（插 `await` 就跨周期，
    /// 旧实现也可能不回调 → 假绿）；写在闭包内部则依赖失效早于订阅建立，同样可能不回调。
    @MainActor
    func testListenStartMsChangeIsInvisibleToObservation() async throws {
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        // onChange 是 @Sendable 闭包：计数必须走线程安全盒子，不能在闭包外改局部 var
        let counter = HitCounter()

        // 读取（注册依赖，若属性参与 observation）
        withObservationTracking {
            _ = pm.readListenStartMsForTesting
        } onChange: {
            counter.bump()
        }
        // 变更必须放在 apply 闭包**之后**、且不插 await（同 runloop 周期）：
        // 若在闭包内变更，失效发生在订阅建立之前，旧实现也可能不回调 -> 断言假绿。
        pm.startListeningSessionForTesting(at: Self.nowMs() - 1_000)
        // 让出一拍，给 onChange 落地机会（若真有依赖）
        await Task.yield()
        try await Task.sleep(nanoseconds: 30_000_000) // 30ms

        XCTAssertEqual(counter.hits, 0,
                       "listenStartMs 变更不得触发 observation（去掉 @ObservationIgnored 后此处必 ≥1）")
    }

    /// 形态守卫：属性豁免标注 + deinit 内不再直接对 `listenStartMs` 赋值。
    func testListenStartMsIsObservationIgnored() throws {
        let code = Self.codeOnly(try Self.source("TingYou/Playback/PlaybackManager.swift"))
        XCTAssertTrue(code.contains("@ObservationIgnored private var listenStartMs"),
                      "listenStartMs 属纯内部计时用途，必须 @ObservationIgnored（与 deinit 注释自洽）")
        let deinitBody = Self.deinitBody(of: code)
        XCTAssertFalse(deinitBody.isEmpty, "必须截到 deinit 函数体（否则下面的断言失去意义）")
        XCTAssertFalse(deinitBody.contains("listenStartMs = 0"),
                       "deinit 不得再直接对 listenStartMs 赋值（清理统一走 settleListeningSession）")
        XCTAssertTrue(deinitBody.contains("settleListeningSession()"),
                      "deinit 必须经唯一结算实现清理收听会话（结算先于清零）")
    }

    // MARK: - P2-2 · 镜像重建保留播放位置（静默态仍定位历史进度）

    /// 纯函数三态（决策与生产共用同一份实现）：
    /// 抑制态一律用装载目标位置；非抑制态用实时位置；实时位置未知（0）时退回目标位置。
    func testMirrorRebuildStartMsDecision() {
        // 抑制态：静默装载定位到 260s，重建必须仍定位到 260s（不得回章首、不得用实时位置）
        XCTAssertEqual(PlaybackManager.mirrorRebuildStartMs(suppressed: true,
                                                            livePositionMs: 480_000,
                                                            launchStartPosMs: 260_000),
                       260_000,
                       "静默装载态的镜像重建必须保持 applyPlan 的历史定位")
        // 非抑制态：真实收听中（第 8 分钟 = 480s）换镜像，必须续播 480s 而不是回 0
        XCTAssertEqual(PlaybackManager.mirrorRebuildStartMs(suppressed: false,
                                                            livePositionMs: 480_000,
                                                            launchStartPosMs: 260_000),
                       480_000,
                       "真实收听中的镜像重建必须保留实时播放位置（复检 P2-2：此前退回章首）")
        // 非抑制态但实时位置未知（刚装载、尚无时钟拍）→ 退回本次装载目标位置
        XCTAssertEqual(PlaybackManager.mirrorRebuildStartMs(suppressed: false,
                                                            livePositionMs: 0,
                                                            launchStartPosMs: 120_000),
                       120_000,
                       "实时位置未知时不得把已知装载位置抹成 0")
    }

    /// 行为级 ①（旧实现必红）：静默装载后触发镜像重建，播放位置必须仍是装载目标位置。
    /// 旧实现 `loadCurrentChapter()` 不传 startPosMs（缺省 0）→ 位置变 0。
    @MainActor
    func testSuppressedMirrorRebuildKeepsHistoricalPosition() async throws {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5430)
        let chapters = oneBasedChapters(12, durationSec: 1_500)
        let recorder = ProbeHistoryRecorder()
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        pm.historyRecorder = recorder

        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(3), startPosMs: 260_000, silentWrite: true)
        XCTAssertTrue(pm.historyWriteSuppressed, "前置：静默装载必须处于抑制态")
        XCTAssertEqual(pm.currentPositionMs, 260_000, "前置：装载落点即当前位置（260s）")
        try await waitForHistoryIdle(pm)

        pm.rebuildForMirrorRetry()
        XCTAssertTrue(pm.historyWriteSuppressed, "镜像重建不得解除抑制（b56 闸门不得回退）")
        XCTAssertEqual(pm.currentPositionMs, 260_000,
                       "静默态的镜像重建必须仍定位到目标历史位置（旧实现退回 0）")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 0, "静默态的镜像重建不得写历史")
    }

    /// 行为级 ②（旧实现必红）：真实收听中（非抑制态）换镜像，必须保留实时播放位置。
    @MainActor
    func testRealListeningMirrorRebuildKeepsLivePosition() async throws {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5431)
        let chapters = oneBasedChapters(12, durationSec: 1_500)
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())

        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(3), startPosMs: 0, silentWrite: false)
        XCTAssertFalse(pm.historyWriteSuppressed, "前置：非静默装载不得处于抑制态")
        pm.durationMs = 1_500_000
        pm.seek(to: 480_000) // 模拟真实收听推进到第 8 分钟
        XCTAssertEqual(pm.currentPositionMs, 480_000, "前置：实时位置 480s")

        pm.rebuildForMirrorRetry()
        XCTAssertEqual(pm.currentPositionMs, 480_000,
                       "真实收听中的镜像重建必须续播到 480s（旧实现 seek 回章首 = 0）")
        XCTAssertFalse(pm.historyWriteSuppressed, "真实收听中不得因重建进入抑制态")
    }

    /// 形态守卫：重建走纯函数决策 + 仍透传抑制态 + 定位仍在生产实现里（不是用例里）。
    func testRebuildWiresStartPositionThroughPureFunction() throws {
        let code = Self.codeOnly(try Self.source("TingYou/Playback/PlaybackManager.swift"))
        let body = Self.functionBody(of: code, needle: "func rebuildForMirrorRetry")
        XCTAssertFalse(body.isEmpty, "必须截到 rebuildForMirrorRetry 函数体")
        XCTAssertTrue(body.contains("Self.mirrorRebuildStartMs"),
                      "重建起播位置必须经纯函数 decision（生产与用例同一份实现）")
        XCTAssertTrue(body.contains("startPosMs: resumeMs"),
                      "重建必须把起播位置传给 loadCurrentChapter（复检 P2-2 的修复点）")
        XCTAssertTrue(body.contains("silentWrite: self.historyWriteSuppressed"),
                      "重建仍必须透传当前抑制态（b56 P1-A 修复不得回退）")
    }

    // MARK: - P2-3 · 章节自然播完（.stop）必须写历史，且过静默闸门

    /// 行为级（旧实现必红）：顺序播放到最后一章、章节自然播完 → `.stop`。
    /// 旧实现只置 `isPlaying = false`，历史零写入；修后必须落一条**章末位置**记录。
    @MainActor
    func testChapterFinishedStopWritesHistoryAtChapterEnd() async throws {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5432)
        let chapters = oneBasedChapters(3, durationSec: 1_500)
        let recorder = ProbeHistoryRecorder()
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        pm.historyRecorder = recorder
        // 顺序播放（默认即 sequence，这里显式置位并还原，避免其他用例污染）
        let originalMode = pm.playMode
        defer { pm.setPlayMode(originalMode) }
        pm.setPlayMode(.sequence)

        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(2), startPosMs: 0, silentWrite: false)
        XCTAssertEqual(pm.currentChapterIdx, 2, "前置：定位到末章（数组位置 2）")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 1, "前置：非静默装载本身写一条起点记录")

        pm.durationMs = 1_500_000 // 章时长 1500s（真机由 readyToPlay 回填，沙箱手动注入）
        pm.simulateChapterFinishedForTesting()

        XCTAssertFalse(pm.isPlaying, "到达章尾必须停播（顺序模式到尾即停）")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 2, "章末必须再落一条历史（复检 P2-3：旧实现零写入）")
        XCTAssertEqual(recorder.writes.last?.chapterTitle, "第3章",
                       "章末记录必须是当前（末）章，不得串到别的章")
        XCTAssertEqual(recorder.writes.last?.positionMs, 1_500_000,
                       "章末记录位置必须为章尾（1500s），与进度条显示一致")
    }

    /// 行为级（闸门硬约束）：静默装载态的 `.stop` 误触发必须被 `recordHistory` 入口
    /// 的静默闸门拦下——不写历史、不解除抑制、不顶 `updatedAt`。
    /// 静默装载不真播放、理论上不触发 `.stop`；镜像链拆条目 / 迟到通知等异常路径
    /// 才可能误触发，本用例守的正是这条异常路径。
    @MainActor
    func testChapterFinishedStopStaysGatedDuringSilentPending() async throws {
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 5433)
        let chapters = oneBasedChapters(3, durationSec: 1_500)
        let recorder = ProbeHistoryRecorder()
        let suppressed = HitCounter()
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        pm.historyRecorder = recorder
        pm.onSuppressedHistoryWriteForTesting = { suppressed.bump() }
        let originalMode = pm.playMode
        defer { pm.setPlayMode(originalMode) }
        pm.setPlayMode(.sequence)

        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(2), startPosMs: 260_000, silentWrite: true)
        XCTAssertTrue(pm.historyWriteSuppressed, "前置：静默装载必须处于抑制态")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 0, "前置：静默装载不写历史")

        pm.durationMs = 1_500_000
        pm.simulateChapterFinishedForTesting()

        XCTAssertTrue(pm.historyWriteSuppressed, "章末分支不得解除抑制（闸门零回退）")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 0,
                       "静默态的章末写必须被闸门拦下（不得绕过 recordHistory 入口）")
        XCTAssertGreaterThanOrEqual(suppressed.hits, 1,
                                    "闸门必须确实拦到了这次写（防「靠 recorder 为空假绿」）")
    }

    /// 形态守卫：`.stop` 分支走 recordHistory 入口；播完通知带当前条目身份守卫
    /// （切章 / 镜像重建拆旧条目的迟到通知不得触发章末动作）。
    func testStopBranchRoutesThroughGateAndNotificationIsGuarded() throws {
        let code = Self.codeOnly(try Self.source("TingYou/Playback/PlaybackManager.swift"))
        let body = Self.functionBody(of: code, needle: "private func onChapterFinished")
        XCTAssertFalse(body.isEmpty, "必须截到 onChapterFinished 函数体")
        XCTAssertTrue(body.contains("recordHistory(force: true, positionMs: currentPositionMs)"),
                      ".stop 分支必须经 recordHistory 入口落库（唯一入口 + 同一道闸门）")
        XCTAssertFalse(body.contains("enqueueHistory"),
                      ".stop 分支不得绕过 recordHistory 直接入队（闸门会被跳过）")
        XCTAssertTrue(code.contains("finished === self?.player.currentItem"),
                      "播完通知必须校验「当前条目」，防止旧条目迟到通知误触发章末写入")
    }

    // MARK: - 工具：源码读取 / 剔注释 / 截函数体

    private static func source(_ rel: String) throws -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("\(rel) 不存在：\(path)——路径布局变化时请同步修正本测试")
            throw NSError(domain: "Build57FeatureTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing source \(rel)"])
        }
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(rel) 不可读：\(path)")
            throw NSError(domain: "Build57FeatureTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "unreadable source \(rel)"])
        }
        return src
    }

    /// 剔除整行注释：删除说明注释里含被断言的标识符名，参与判定前必须剔除。
    private static func codeOnly(_ src: String) -> String {
        src.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 截取函数体：从 needle 所在行起、到下一个函数声明行（不含）止。
    ///
    /// 边界必须同时认 `private func` / `fileprivate func` 等带修饰符的声明——
    /// 只认裸 `func` 时 `onChapterFinished()` 会一路吞到类末尾，把后面的
    /// `checkOutroSkip` 也算进判定范围（断言就会对着整文件成立，失去判别力）。
    private static func functionBody(of code: String, needle: String) -> String {
        let lines = code.split(separator: "\n").map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(needle) }) else { return "" }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.isFunctionDeclarationLine(trimmed) && !body.isEmpty { break }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }

    /// 是否函数声明行（含 `@MainActor` 之外常见访问修饰符前缀）。
    private static func isFunctionDeclarationLine(_ trimmed: String) -> Bool {
        let modifiers = ["", "private ", "fileprivate ", "internal ", "public ",
                         "override ", "final ", "static ", "private static ",
                         "fileprivate static ", "class "]
        return modifiers.contains { mod in
            trimmed.hasPrefix(mod + "func ") || trimmed.hasPrefix(mod + "deinit {")
        }
    }

    /// 截取 deinit 函数体（deinit 是类内最后一个成员，取到类结尾即可）。
    private static func deinitBody(of code: String) -> String {
        let lines = code.split(separator: "\n").map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("deinit {")
        }) else { return "" }
        let tail = Array(lines[(start + 1)...])
        // 去掉末尾的类/函数收括号
        var body = tail
        while let last = body.last,
              ["}", "}"].contains(last.trimmingCharacters(in: .whitespaces)) {
            body.removeLast()
        }
        return body.joined(separator: "\n")
    }
}
