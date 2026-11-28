import XCTest
@testable import TingYou

final class ChapterPrefetchTests: XCTestCase {

    func testPrefetchWindowCoversFiveFollowingChapters() {
        XCTAssertEqual(PlaybackManager.prefetchRange(currentIndex: 0, totalCount: 20), 1..<6)
        XCTAssertEqual(PlaybackManager.prefetchRange(currentIndex: 7, totalCount: 20), 8..<13)
    }

    func testPrefetchWindowStopsAtLastChapter() {
        XCTAssertEqual(PlaybackManager.prefetchRange(currentIndex: 17, totalCount: 20), 18..<20)
        XCTAssertEqual(PlaybackManager.prefetchRange(currentIndex: 18, totalCount: 20), 19..<20)
        XCTAssertNil(PlaybackManager.prefetchRange(currentIndex: 19, totalCount: 20))
    }

    func testCacheFileNameIsStableAndFilesystemSafe() {
        let name = ChapterAudioCache.sanitizedFileName(forKey: "tingyou-chapter://1/2?x=3")
        XCTAssertTrue(name.hasSuffix(".m4a"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("?"))
        XCTAssertEqual(name, ChapterAudioCache.sanitizedFileName(forKey: "tingyou-chapter://1/2?x=3"))
    }

    /// 源码形态守卫：播放装载必须优先命中本地缓存，预取必须覆盖后续章节。
    func testPlaybackWiresDiskCacheAndFiveChapterWindow() throws {
        let rel = "TingYou/Playback/PlaybackManager.swift"
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw NSError(domain: "TestSourceMissing", code: 1)
        }
        XCTAssertTrue(src.contains("ChapterAudioCache.shared.cachedFileURL"),
                      "播放装载未接入本地缓存")
        XCTAssertTrue(src.contains("prefetchAheadCount = 5"),
                      "预取窗口不是 5 章")
        XCTAssertTrue(src.contains("ChapterAudioCache.shared.prefetch"),
                      "预取未下载音频到本地")
    }
}
