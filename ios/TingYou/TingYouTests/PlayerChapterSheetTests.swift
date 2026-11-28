import XCTest

/// 播放器章节面板与发现页书籍章节列表同构：
/// 当前播放章居中、标题+时长两行、当前章音量标志、之前章节 ✓。
final class PlayerChapterSheetTests: XCTestCase {
    private static func sheetSource() throws -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let src = (testDir as NSString).deletingLastPathComponent
            + "/TingYou/UI/Components/SpeedSheet.swift"
        return try String(contentsOfFile: src, encoding: .utf8)
    }

    func testChapterSheetCentersCurrentChapter() throws {
        let src = try Self.sheetSource()
        XCTAssertTrue(src.contains("proxy.scrollTo(currentIdx, anchor: .center)"),
                      "当前播放章必须居中显示（上下都有章节）")
        XCTAssertTrue(src.contains("ScrollViewReader"), "缺少滚动定位容器")
    }

    func testChapterSheetShowsDurationAndVolumeIcon() throws {
        let src = try Self.sheetSource()
        XCTAssertTrue(src.contains("chapters[i].durationSec"),
                      "章节行必须展示时长（与发现页书籍章节一致）")
        XCTAssertTrue(src.contains("speaker.wave.3.fill"),
                      "当前播放章必须带音量标志")
        XCTAssertTrue(src.contains("player_chapter_now_playing"),
                      "音量标志缺少可访问标识")
    }

    func testChapterSheetMarksListenedChapters() throws {
        let src = try Self.sheetSource()
        XCTAssertTrue(src.contains("let isListened = i < currentIdx"),
                      "当前章之前的章节必须标记为已听")
        XCTAssertTrue(src.contains("player_chapter_done_"), "已听 ✓ 锚点缺失")
    }
}
