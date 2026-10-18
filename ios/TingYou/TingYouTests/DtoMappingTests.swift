import XCTest
@testable import TingYou

final class DtoMappingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func testRankResponseItemsEnvelope() throws {
        let payload = """
            {"detail":"成功","generated_at":1791592524,"group":"latest","has_more":true,
             "items":[{"author":"丁灵司","cat":"有声小说","cat_id":2,"count":296,
             "cover_url":"https://file.tingyou8.vip/pic/x.jpg","id":8488062519,
             "intro":"完全不懂历史理科生朱由检穿越到明末","play_count":1234567,
             "status":1,"title":"大明：朕，崇祯，只想摆烂","type":"玄幻奇幻","updated_at":1791540230}],
             "page":1,"page_size":20,"total":100}
        """.data(using: .utf8)!
        let resp = try decoder.decode(RankResponse.self, from: payload)
        XCTAssertEqual(resp.items.count, 1)
        let dto = resp.items[0]
        XCTAssertEqual(dto.id, 8488062519)
        XCTAssertEqual(dto.catId, 2)
        XCTAssertEqual(dto.count, 296)
        XCTAssertEqual(dto.status, 1)
        XCTAssertEqual(dto.playCount, 1234567)
        XCTAssertEqual(dto.toDomain().intro, "完全不懂历史理科生朱由检穿越到明末")
        XCTAssertEqual(dto.toDomain().category, "有声小说")
        XCTAssertEqual(dto.toDomain().categoryId, 2)
    }

    func testSearchResponseDescriptionUnifiesToIntro() throws {
        let payload = """
            {"detail":"成功","has_more":false,
             "results":[{"anonymous":false,"author":"佚名","cat":"","count":5201,
             "cover_url":"https://file.tingyou8.vip/pic/y.jpeg","description":"经典超燃白金小说",
             "id":92,"status":1,"title":"搜索结果专辑"}],
             "total":1}
        """.data(using: .utf8)!
        let resp = try decoder.decode(SearchResponse.self, from: payload)
        XCTAssertEqual(resp.results.count, 1)
        let domain = resp.results[0].toDomain()
        XCTAssertEqual(domain.albumId, 92)
        XCTAssertEqual(domain.intro, "经典超燃白金小说")
        XCTAssertEqual(resp.hasMore, false)
    }

    func testAlbumDetailSynopsisUnifiesToIntro() throws {
        let payload = """
            {"id":8488062519,"title":"大明：朕，崇祯，只想摆烂","author":"丁灵司","teller":"安燃",
             "cover_url":"https://file.tingyou8.vip/pic/x.jpg","status":1,"count":296,
             "updated_at":1791540230,"type":"玄幻奇幻","cat":"有声小说",
             "synopsis":"完全不懂历史理科生朱由检穿越到明末"}
        """.data(using: .utf8)!
        let dto = try decoder.decode(AlbumDto.self, from: payload)
        let domain = dto.toDomain()
        XCTAssertEqual(domain.albumId, 8488062519)
        XCTAssertEqual(domain.teller, "安燃")
        XCTAssertEqual(domain.chapterCount, 296)
        XCTAssertEqual(domain.intro, "完全不懂历史理科生朱由检穿越到明末")
    }

    func testChaptersIndexStartsAtOne() throws {
        let payload = """
            {"id":8488062519,"available":true,"count":296,
             "chapters":[{"id":311620740,"index":1,"title":"01崇祯的自我修养","duration":426},
                         {"id":311620741,"index":2,"title":"02安燃爆笑历史类","duration":375}]}
        """.data(using: .utf8)!
        let resp = try decoder.decode(ChaptersResponse.self, from: payload)
        XCTAssertEqual(resp.chapters.count, 2)
        XCTAssertEqual(resp.chapters[0].index, 1)
        XCTAssertEqual(resp.chapters[0].title, "01崇祯的自我修养")
        XCTAssertEqual(resp.chapters[0].duration, 426)
        XCTAssertEqual(resp.chapters[1].toDomain().durationSec, 375)
        XCTAssertEqual(resp.available, true)
    }

    func testCategoryResponseDataEnvelope() throws {
        let payload = """
            {"data":[{"id":9783312385,"title":"剑来","author":"大斌","teller":"大斌",
             "cover_url":"https://file.tingyou8.vip/pic/z.gif","status":1,"count":5329,
             "updated_at":1774290416,"type":"玄幻奇幻","cat":"有声小说"}],
             "page":1,"pages":10}
        """.data(using: .utf8)!
        let resp = try decoder.decode(CategoryResponse.self, from: payload)
        XCTAssertEqual(resp.data.count, 1)
        XCTAssertEqual(resp.page, 1)
        XCTAssertEqual(resp.pages, 10)
        XCTAssertEqual(resp.data[0].title, "剑来")
        XCTAssertEqual(resp.data[0].count, 5329)
    }

    func testPlayResponseSignedUrl() throws {
        let payload = #"{"play_url":"https://file.hgeuz.cn/stream/abc?ts=1791590226&sign=3c938250"}"#.data(using: .utf8)!
        let resp = try decoder.decode(PlayResponse.self, from: payload)
        XCTAssertTrue(resp.playUrl?.hasPrefix("https://") ?? false)
        XCTAssertTrue(resp.playUrl?.contains("sign=") ?? false)
    }

    func testFiltersResponseThreeGroups() throws {
        let payload = """
            {"sorts":[{"key":"comprehensive","name":"综合排序"},{"key":"popular","name":"播放最多"}],
             "categories":[{"id":2,"name":"有声小说","types":[{"id":21,"name":"玄幻奇幻"},{"id":22,"name":"都市"}]},
                           {"id":1,"name":"评书","types":[]}],
             "statuses":[{"key":0,"name":"已完结"},{"key":1,"name":"连载中"}]}
        """.data(using: .utf8)!
        let resp = try decoder.decode(FiltersResponse.self, from: payload)
        let domain = resp.toDomain()
        XCTAssertEqual(domain.sorts.count, 2)
        XCTAssertEqual(domain.sorts[0].name, "综合排序")
        XCTAssertEqual(domain.categories.count, 2)
        XCTAssertEqual(domain.categories[0].types.count, 2)
        XCTAssertEqual(domain.categories[0].types[0].name, "玄幻奇幻")
        XCTAssertEqual(domain.statuses[0].key, 0)
        XCTAssertEqual(domain.statuses[0].name, "已完结")
    }

    func testUnknownFieldsTolerated() throws {
        let payload = """
            {"id":1,"title":"t","new_field_added_by_server":123,"another":{"a":1}}
        """.data(using: .utf8)!
        let dto = try decoder.decode(AlbumDto.self, from: payload)
        XCTAssertEqual(dto.id, 1)
        XCTAssertEqual(dto.title, "t")
    }
}
