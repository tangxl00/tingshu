import XCTest
@testable import TingYou

/// 真机 v1.3.3 症状2 修复的回归测试：
/// 书架 HistoryModel/FavoriteModel → Album 映射必须完整保留路由所需的
/// source（音源路由键）、albumId、detailPath，否则点击跳详情后章节加载会失败。
final class ShelfMappingTests: XCTestCase {

    func testHistoryModelToAlbumKeepsRoutingKeys() {
        let h = HistoryModel(
            src: "tingyou",
            albumId: 12345,
            albumTitle: "三体",
            coverUrl: "https://example.com/cover.jpg",
            chapterIdx: 7,
            chapterTitle: "第七章",
            positionMs: 65_000,
            durationMs: 1_800_000,
            detailPath: "/album/12345")
        let album = h.toAlbum()

        XCTAssertEqual(album.source, "tingyou", "source 必须等于 src，否则 SourceRouter 路由错源")
        XCTAssertEqual(album.albumId, 12345)
        XCTAssertEqual(album.title, "三体")
        XCTAssertEqual(album.coverUrl, "https://example.com/cover.jpg")
        XCTAssertEqual(album.detailPath, "/album/12345", "detailPath 是多源章节加载的必填路由参数")
        XCTAssertNil(album.author)
        XCTAssertNil(album.chapterCount)
    }

    func testFavoriteModelToAlbumKeepsRoutingKeys() {
        let f = FavoriteModel(
            src: "bili",  // build 45 · 反馈 3：悦听下架，样本改 B站
            albumId: 998,
            title: "凡人修仙传",
            author: "忘语",
            teller: "大灰狼",
            coverUrl: nil,
            chapterCount: 1200,
            status: 1,
            lastChapterIdx: 88,
            detailPath: "book/998")
        let album = f.toAlbum()

        XCTAssertEqual(album.source, "bili")
        XCTAssertEqual(album.albumId, 998)
        XCTAssertEqual(album.title, "凡人修仙传")
        XCTAssertEqual(album.author, "忘语")
        XCTAssertEqual(album.teller, "大灰狼")
        XCTAssertEqual(album.chapterCount, 1200)
        XCTAssertEqual(album.status, 1)
        XCTAssertEqual(album.detailPath, "book/998")
        XCTAssertNil(album.coverUrl)
    }

    func testHistoryToAlbumRoundTripsIntoAlbumIdentity() {
        let h = HistoryModel(
            src: "mekui",
            albumId: 42,
            albumTitle: "斗罗大陆",
            chapterIdx: 1,
            chapterTitle: "第一章",
            positionMs: 0,
            durationMs: 0)
        let album = h.toAlbum()
        XCTAssertEqual(album.id, 42)
        XCTAssertEqual(album.source, "mekui")
    }
}
