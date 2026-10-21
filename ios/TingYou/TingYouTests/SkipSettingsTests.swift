import XCTest
@testable import TingYou

/// build 25（对齐安卓 v1.3.0 item 8）：片头/片尾跳过测试。
/// 覆盖：起播位置决策（纯函数 + prepareQueue 集成断言历史落库位置）、
/// 片尾跳过判定纯函数（与自动连播一致的切章入口在 nextChapter，末章不越界）、
/// 按书持久化与换书刷新、时长选择器写值与上限。
final class SkipSettingsTests: XCTestCase {

    // MARK: - 起播位置决策（chapterStartMs）

    /// 新章（无恢复进度）起播位置 = 片头跳过秒数。
    func testChapterStartUsesIntroWhenNoResume() {
        XCTAssertEqual(PlaybackManager.chapterStartMs(startPosMs: 0, introSec: 30), 30_000)
        XCTAssertEqual(PlaybackManager.chapterStartMs(startPosMs: 0, introSec: 0), 0, "片头关闭时从 0 起播")
    }

    /// 恢复播放（有进度）优先，不被片头跳过覆盖。
    func testChapterStartKeepsResumePositionOverIntro() {
        XCTAssertEqual(PlaybackManager.chapterStartMs(startPosMs: 120_000, introSec: 30), 120_000,
                       "恢复进度必须优先于片头跳过")
    }

    /// 集成：prepareQueue 起播即落历史，位置应带片头跳过秒数（对齐安卓 applyIntroSkip）。
    func testPrepareQueueRecordsIntroSkippedStartPosition() async throws {
        let defaults = UserDefaults(suiteName: "SkipSettingsTests-\(UUID().uuidString)")!
        let store = SkipSettingsStore(defaults: defaults)
        store.setIntro(30, src: "tingyou", albumId: 501)

        let recorder = ProbeHistoryRecorder()
        let pm = PlaybackManager(playbackRepository: nil, skipStore: store)
        pm.historyRecorder = recorder
        pm.playQueue(album: makeAlbum(id: 501), chapters: makeChapters(), startIdx: 0)

        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.first?.positionMs, 30_000,
                       "起播历史位置应为片头跳过后的 30s，而非 0")
        // 等排水后 PM 处于播放态，测试收尾暂停结算
        pm.pause()
    }

    // MARK: - 片尾跳过判定（shouldSkipOutro）

    /// 剩余时长 ≤ 指定秒触发；未到 / 关闭 / 无时长不触发。
    func testShouldSkipOutroBoundaries() {
        // 剩余恰好等于指定秒 → 触发（对齐安卓 remainingMs <= outroMs）
        XCTAssertTrue(PlaybackManager.shouldSkipOutro(positionMs: 1_770_000, durationMs: 1_800_000, outroSec: 30))
        // 剩余 31s、指定 30s → 不触发
        XCTAssertFalse(PlaybackManager.shouldSkipOutro(positionMs: 1_769_000, durationMs: 1_800_000, outroSec: 30))
        // 片尾关闭（0）→ 不触发
        XCTAssertFalse(PlaybackManager.shouldSkipOutro(positionMs: 1_790_000, durationMs: 1_800_000, outroSec: 0))
        // 时长未知（0）→ 不触发
        XCTAssertFalse(PlaybackManager.shouldSkipOutro(positionMs: 100, durationMs: 0, outroSec: 30))
        // 已播完（剩余 ≤ 0）→ 不触发（交给自然播完路径）
        XCTAssertFalse(PlaybackManager.shouldSkipOutro(positionMs: 1_800_000, durationMs: 1_800_000, outroSec: 30))
    }

    /// 片尾触发的切章入口与自动连播一致（nextChapter），末章不越界。
    func testNextChapterDoesNotOverflowOnLastChapter() {
        let pm = PlaybackManager(playbackRepository: nil,
                                 skipStore: SkipSettingsStore(defaults: UserDefaults(suiteName: "SkipSettingsTests-\(UUID().uuidString)")!))
        pm.prepareQueue(album: makeAlbum(id: 502), chapters: makeChapters(), startIdx: 2) // 末章
        pm.nextChapter() // 片尾跳过在末章触发时的调用
        XCTAssertEqual(pm.currentChapterIdx, 2, "末章无下一章可切，章节不应越界")
    }

    // MARK: - 按书持久化与换书刷新

    /// SkipSettingsStore 按（src, albumId）隔离；写入 clamp 到 0...600（对齐安卓 MAX_SECONDS）。
    func testSkipStorePerBookIsolationAndClamp() {
        let store = SkipSettingsStore(defaults: UserDefaults(suiteName: "SkipSettingsTests-\(UUID().uuidString)")!)
        XCTAssertEqual(store.intro(for: "tingyou", albumId: 1), 0, "默认关闭")
        XCTAssertEqual(store.outro(for: "tingyou", albumId: 1), 0, "默认关闭")

        store.setIntro(45, src: "tingyou", albumId: 1)
        store.setOutro(60, src: "tingyou", albumId: 1)
        store.setIntro(20, src: "tingyou", albumId: 2) // 同源不同书
        store.setIntro(15, src: "ting15", albumId: 1)  // 同书号不同源

        XCTAssertEqual(store.intro(for: "tingyou", albumId: 1), 45)
        XCTAssertEqual(store.outro(for: "tingyou", albumId: 1), 60)
        XCTAssertEqual(store.intro(for: "tingyou", albumId: 2), 20, "另一本书的设置互不影响")
        XCTAssertEqual(store.intro(for: "ting15", albumId: 1), 15, "另一源的设置互不影响")

        store.setIntro(999, src: "tingyou", albumId: 1)
        XCTAssertEqual(store.intro(for: "tingyou", albumId: 1), 600, "写入上限 clamp 到 600 秒（对齐安卓）")
        store.setIntro(-5, src: "tingyou", albumId: 1)
        XCTAssertEqual(store.intro(for: "tingyou", albumId: 1), 0, "负值 clamp 到 0")
    }

    /// PlaybackManager 设置入口写当前书，换书后读值自动刷新。
    func testSetSkipWritesCurrentBookAndRefreshesOnBookChange() {
        let store = SkipSettingsStore(defaults: UserDefaults(suiteName: "SkipSettingsTests-\(UUID().uuidString)")!)
        let pm = PlaybackManager(playbackRepository: nil, skipStore: store)

        // 无当前书：设置入口不落库（读回仍默认 0）
        pm.setIntroSkip(30)
        XCTAssertEqual(pm.introSkipSeconds, 0)

        pm.prepareQueue(album: makeAlbum(id: 501), chapters: makeChapters(), startIdx: 0)
        pm.setIntroSkip(30)
        pm.setOutroSkip(90)
        XCTAssertEqual(pm.introSkipSeconds, 30)
        XCTAssertEqual(pm.outroSkipSeconds, 90)

        // 换书：值刷新为新书的独立设置（默认 0）
        pm.prepareQueue(album: makeAlbum(id: 503), chapters: makeChapters(), startIdx: 0)
        XCTAssertEqual(pm.introSkipSeconds, 0, "换书后应读新书的设置（默认关闭）")
        XCTAssertEqual(pm.outroSkipSeconds, 0)
    }

    // MARK: - 辅助

    private func makeAlbum(id: Int64) -> Album {
        Album(albumId: id, title: "跳过测试书", author: nil, teller: nil, coverUrl: nil,
              intro: nil, category: nil, categoryId: nil, type: nil, typeId: nil,
              status: nil, chapterCount: nil, updatedAt: nil, playCount: nil,
              available: nil, source: "tingyou", detailPath: nil)
    }

    private func makeChapters() -> [Chapter] {
        [
            Chapter(chapterId: 1, index: 0, title: "第01集", durationSec: 1800),
            Chapter(chapterId: 2, index: 1, title: "第02集", durationSec: 1750),
            Chapter(chapterId: 3, index: 2, title: "第03集", durationSec: 1600),
        ]
    }

    private func waitForHistoryIdle(_ pm: PlaybackManager, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !pm.isHistoryWriteIdle && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(pm.isHistoryWriteIdle, "历史排水应在时限内收敛")
    }

    /// 起播位置断言用：只关心首次（force）写入的 positionMs。
    final class ProbeHistoryRecorder: PlaybackHistoryRecording, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var writes: [(chapterTitle: String, positionMs: Int64)] = []

        func recordHistory(album: Album, chapter: Chapter, positionMs: Int64, durationMs: Int64) async {
            lock.lock()
            writes.append((chapter.title, positionMs))
            lock.unlock()
        }
    }
}
