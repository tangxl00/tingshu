import XCTest
@testable import TingYou

/// build 20 必修 2 回归：书架恢复播放重建完整章节队列。
/// 判别力：旧实现无条件传单章数组，fullQueue 断言在旧实现下必失败。
final class HistoryResumeTests: XCTestCase {

    private func chapter(_ index: Int, title: String = "第\(index)集") -> Chapter {
        Chapter(chapterId: Int64(index), index: index, title: title, durationSec: nil)
    }

    // MARK: - 成功路径：重建完整队列

    func testPlanBuildsFullQueueWithCorrectStartIndex() async {
        let fetched = [chapter(1), chapter(2), chapter(3), chapter(4)]
        let planner = HistoryResumePlanner { _, _, _ in fetched }
        let outcome = await planner.plan(
            src: "ting15", albumId: 501, detailPath: "/book/501.html",
            chapterIdx: 2, chapterTitle: "第02集"
        )
        guard case .fullQueue(let chapters, let startIdx) = outcome else {
            return XCTFail("拉取成功应返回完整队列，实际 \(outcome)")
        }
        XCTAssertEqual(chapters.count, 4, "恢复后队列应含全部章节（旧实现只有 1 章）")
        XCTAssertEqual(chapters.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(startIdx, 1, "第 2 章应定位到数组位置 1")
    }

    func testPlanMatchesByTitleWhenIndexMissing() async {
        // 源重排了章节 index，但标题还在 → 标题匹配兜底
        let fetched = [chapter(11), chapter(12), Chapter(chapterId: 99, index: 13, title: "第02集", durationSec: nil)]
        let planner = HistoryResumePlanner { _, _, _ in fetched }
        let outcome = await planner.plan(
            src: "ting15", albumId: 502, detailPath: nil,
            chapterIdx: 2, chapterTitle: "第02集"
        )
        guard case .fullQueue(_, let startIdx) = outcome else {
            return XCTFail("应返回完整队列，实际 \(outcome)")
        }
        XCTAssertEqual(startIdx, 2, "index 无匹配时应按标题定位到数组位置 2")
    }

    func testPlanClampsStartIndexWhenNoMatch() async {
        let fetched = [chapter(1), chapter(2), chapter(3)]
        let planner = HistoryResumePlanner { _, _, _ in fetched }
        let outcome = await planner.plan(
            src: "mekui", albumId: 503, detailPath: nil,
            chapterIdx: 99, chapterTitle: "不存在的章节"
        )
        guard case .fullQueue(_, let startIdx) = outcome else {
            return XCTFail("无匹配也应返回完整队列（夹取定位），实际 \(outcome)")
        }
        XCTAssertEqual(startIdx, 2, "无任何匹配时夹取到最后一章，不越界")
    }

    // MARK: - 降级路径

    func testPlanFallsBackToSingleChapterOnFetchError() async {
        // 判别力：拉取失败必须降级单章且不崩溃（保留旧的恢复能力）
        struct Boom: Error {}
        let planner = HistoryResumePlanner { _, _, _ in throw Boom() }
        let outcome = await planner.plan(
            src: "ting15", albumId: 504, detailPath: "/gone.html",
            chapterIdx: 3, chapterTitle: "第03集"
        )
        guard case .singleChapter(let ch) = outcome else {
            return XCTFail("拉取失败应降级单章，实际 \(outcome)")
        }
        XCTAssertEqual(ch.title, "第03集")
        XCTAssertEqual(ch.index, 3)
    }

    func testPlanFallsBackToSingleChapterOnEmptyChapters() async {
        let planner = HistoryResumePlanner { _, _, _ in [] }
        let outcome = await planner.plan(
            src: "ting15", albumId: 505, detailPath: nil,
            chapterIdx: 1, chapterTitle: "第01集"
        )
        guard case .singleChapter = outcome else {
            return XCTFail("空章节列表应降级单章，实际 \(outcome)")
        }
    }

    // MARK: - locate 纯函数

    func testLocatePrefersExactIndexThenChapterIdThenTitle() {
        let chapters = [
            Chapter(chapterId: 101, index: 1, title: "A", durationSec: nil),
            Chapter(chapterId: 2, index: 2, title: "B", durationSec: nil),  // chapterId 恰为 2，index 匹配优先
            Chapter(chapterId: 103, index: 3, title: "C", durationSec: nil),
        ]
        XCTAssertEqual(HistoryResumePlanner.locate(chapterIdx: 2, chapterTitle: "B", in: chapters), 1, "index 精确匹配")
        XCTAssertEqual(HistoryResumePlanner.locate(chapterIdx: 103, chapterTitle: "X", in: chapters), 2, "index 无匹配时 chapterId 兜底")
        XCTAssertEqual(HistoryResumePlanner.locate(chapterIdx: 7, chapterTitle: "C", in: chapters), 2, "index/chapterId 均无匹配时标题兜底")
        XCTAssertEqual(HistoryResumePlanner.locate(chapterIdx: 99, chapterTitle: "", in: chapters), 2, "全无匹配夹取到末尾")
    }
}
