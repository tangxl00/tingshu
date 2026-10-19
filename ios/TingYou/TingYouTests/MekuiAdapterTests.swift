import XCTest
@testable import TingYou

/// 书音 FM（mekui）适配器：wapseries 签名黄金值 + 详情解析黄金样本。
/// 黄金值由独立 Python 参考实现预计算（与站点公开 JS 模块 84423 function h 同构）。
final class MekuiAdapterTests: XCTestCase {

    // MARK: - 签名黄金值（P0-3 核心算法锁定）

    func testWapseriesSignatureGoldenVector1() {
        // 参数 {act=wapseries, mod=movie, id=123, movieId=456, t=1700000000}
        // 参考实现：sorted "act=wapseries&id=123&mod=movie&movieId=456&t=1700000000" + "&token=<SITE_TOKEN>" 的 MD5
        XCTAssertEqual(
            MekuiAdapter.wapseriesSignature(albumId: "123", movieId: "456", t: "1700000000"),
            "2b2a9f4ef704410760900aa6931723f5")
    }

    func testWapseriesSignatureGoldenVector2() {
        XCTAssertEqual(
            MekuiAdapter.wapseriesSignature(albumId: "88801", movieId: "3", t: "1760000000"),
            "cf7c60bc57c5044634f2278658f3aa82")
    }

    func testSignatureIsDeterministic() {
        let a = MekuiAdapter.wapseriesSignature(albumId: "100", movieId: "200", t: "1700000001")
        let b = MekuiAdapter.wapseriesSignature(albumId: "100", movieId: "200", t: "1700000001")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32, "MD5 hex 应为 32 字符")
    }

    // MARK: - 详情 / 章节解析（纯函数黄金样本）

    private func detailJson() -> [String: Any] {
        [
            "code": 1,
            "data": [
                "detail": [
                    "id": "88801",
                    "title": "三体（广播剧）",
                    "titlepic": "https://img.mekui.com/cover/88801.jpg",
                    "playadmin": "原作者",
                    "player": "主播团队",
                    "moviesay": "一部科幻巨著的有声演绎。",
                    "firstclassname": "科幻",
                    "keyboard": "三体,科幻",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private func chaptersJson() -> [String: Any] {
        [
            "code": 1,
            "data": [
                "moielist": [
                    ["id": "3", "title": "第01集", "level": "0", "control": "0"],
                    ["id": "4", "title": "第02集", "level": "0", "control": "0"],
                    ["id": "5", "title": "第03集（付费）", "level": "1", "control": "0"],
                    ["id": "6", "title": "第04集（受限）", "level": "0", "control": "2"],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
    }

    func testParseDetailGoldenSample() throws {
        let d = try MekuiAdapter.parseDetail(detailJson(), chaptersJson(), id: "88801")
        XCTAssertEqual(d.id, "88801")
        XCTAssertEqual(d.title, "三体（广播剧）")
        XCTAssertEqual(d.cover, "https://img.mekui.com/cover/88801.jpg")
        XCTAssertEqual(d.artist, "原作者")
        XCTAssertEqual(d.player, "主播团队")
        XCTAssertEqual(d.description, "一部科幻巨著的有声演绎。")
        XCTAssertEqual(d.category, "科幻")
        XCTAssertEqual(d.chapters.count, 4)
        XCTAssertEqual(d.chapters[0].id, "3")
        XCTAssertEqual(d.chapters[0].title, "第01集")
        XCTAssertEqual(d.chapters[0].paid, false)
    }

    func testParseDetailMarksPaidChapters() throws {
        let d = try MekuiAdapter.parseDetail(detailJson(), chaptersJson(), id: "88801")
        XCTAssertFalse(d.chapters[0].paid)
        XCTAssertFalse(d.chapters[1].paid)
        XCTAssertTrue(d.chapters[2].paid, "level != 0 应打付费标")
        XCTAssertTrue(d.chapters[3].paid, "control != 0 应打付费标")
    }

    func testParseDetailThrowsWithoutDataDetail() {
        XCTAssertThrowsError(try MekuiAdapter.parseDetail(["code": 1], chaptersJson(), id: "1"))
        XCTAssertThrowsError(try MekuiAdapter.parseDetail(["data": ["x": 1]], chaptersJson(), id: "1"))
    }

    func testParseDetailDegradesOnMissingChapters() throws {
        let d = try MekuiAdapter.parseDetail(detailJson(), ["code": 1], id: "88801")
        XCTAssertEqual(d.title, "三体（广播剧）")
        XCTAssertTrue(d.chapters.isEmpty, "章节缺失时降级为空列表，不抛错")
    }

    func testChapterIndexFallsBackToPosition() throws {
        let d = try MekuiAdapter.parseDetail(detailJson(), chaptersJson(), id: "88801")
        XCTAssertEqual(d.chapters[0].index, 3)
        XCTAssertEqual(d.chapters[1].index, 4)
    }
}
