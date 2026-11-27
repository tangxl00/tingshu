import XCTest
@testable import TingYou

/// UI 增强回归测试（对齐 abts 详情页三项交互）：
/// 1. 章节标题序号去重——行为级，正则纯函数正反例；
/// 2. 已听 ✓ + 置灰 + 目录计数——源码形态守卫（SwiftUI View 无法脱离宿主实例化）；
/// 3. 正序/倒序——源码形态守卫，且必须保持播放队列口径不变。
final class AlbumChapterUITests: XCTestCase {

    // MARK: - 1. 标题序号去重（行为级）

    func testHasOwnIndexChineseNumbers() {
        XCTAssertTrue(ChapterTitleFormatting.hasOwnIndex("第3集 楔子"))
        XCTAssertTrue(ChapterTitleFormatting.hasOwnIndex("第 十二 回 风云"))
        XCTAssertTrue(ChapterTitleFormatting.hasOwnIndex("第一章 开端"))
    }

    func testHasOwnIndexPLPrefix() {
        XCTAssertTrue(ChapterTitleFormatting.hasOwnIndex("P1 绪论"))
        XCTAssertTrue(ChapterTitleFormatting.hasOwnIndex("p12 尾声"))
        XCTAssertTrue(ChapterTitleFormatting.hasOwnIndex("P3"))
    }

    func testHasOwnIndexArabicWithSeparator() {
        XCTAssertTrue(ChapterTitleFormatting.hasOwnIndex("5. 江湖"))
        XCTAssertTrue(ChapterTitleFormatting.hasOwnIndex("12、夜雨"))
        XCTAssertTrue(ChapterTitleFormatting.hasOwnIndex("3 风云再起"))
    }

    func testHasOwnIndexRejectsPlainTitles() {
        XCTAssertFalse(ChapterTitleFormatting.hasOwnIndex("绪论"))
        XCTAssertFalse(ChapterTitleFormatting.hasOwnIndex("江湖夜雨十年灯"))
        // 数字在中间/结尾不应误判
        XCTAssertFalse(ChapterTitleFormatting.hasOwnIndex("大闹 天宫 3"))
        // 纯数字后无空白与后续字符，B 站分 P 标题极少单独数字，按无序号处理
        XCTAssertFalse(ChapterTitleFormatting.hasOwnIndex("123"))
    }

    // MARK: - 2 & 3. UI 接线形态守卫

    /// 与 Build44FeedbackTests.loadSource 同口径：#filePath 推导，不依赖 working-directory。
    private static func albumSource() throws -> String {
        let rel = "TingYou/UI/Album/AlbumScreen.swift"
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(rel) 不可读：\(path)——路径布局变化时请同步修正本测试")
            throw NSError(domain: "TestSourceMissing", code: 1)
        }
        return src
    }

    /// 三种交互必须都接在章节 Section：已听✓、目录计数、正序/倒序。
    func testAlbumScreenWiresThreeInteractions() throws {
        let src = try Self.albumSource()
        XCTAssertTrue(src.contains("album_chapter_done_"), "已听章节 ✓ 锚点缺失")
        XCTAssertTrue(src.contains("已听 \\("), "目录已听计数缺失")
        XCTAssertTrue(src.contains("chaptersReversed"), "正序/倒序状态缺失")
        XCTAssertTrue(src.contains("album_chapter_order_toggle"), "排序切换锚点缺失")
    }

    /// 倒序只能作用于展示，playChapter 必须传原 chapters——防止改序后 chapterIdx 错位。
    func testReversedOrderDoesNotTouchPlayQueue() throws {
        let src = try Self.albumSource()
        XCTAssertTrue(src.contains("ForEach(displayedChapters)"), "展示必须用 displayedChapters")
        XCTAssertTrue(src.contains("playChapter(ch)"), "点击必须仍按原章对象播放")
        XCTAssertTrue(src.contains("chaptersReversed ? chapters.reversed() : chapters"),
                      "displayedChapters 必须只改展示顺序")
        XCTAssertFalse(src.contains("playChapter(displayedChapters"), "不得把展示顺序写入播放路径")
    }
}
