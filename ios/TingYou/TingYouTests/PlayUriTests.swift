import XCTest
@testable import TingYou

final class PlayUriTests: XCTestCase {

    func testBuildUriStringCarriesSrcAndParsesBack() {
        let uri = PlayUri.build(src: "ting15", albumId: 12345, chapterIdx: 7)
        XCTAssertEqual(uri, "tingyou-chapter://play?src=ting15&album_id=12345&chapter_idx=7")
        let parsed = PlayUri.parse(uri)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.src, "ting15")
        XCTAssertEqual(parsed?.albumId, 12345)
        XCTAssertEqual(parsed?.chapterIdx, 7)
    }

    func testLegacyUriWithoutSrcFallsBack() {
        let legacy = "tingyou-chapter://play?album_id=999&chapter_idx=3"
        let parsed = PlayUri.parse(legacy)
        // PlayUri.parse requires all three fields; legacy without src returns nil
        XCTAssertNil(parsed)
    }

    func testMalformedUriDegrades() {
        XCTAssertNil(PlayUri.parse("tingyou-chapter://play"))
        XCTAssertNil(PlayUri.parse("tingyou-chapter://play?novalue"))
    }

    func testNonAsciiAudioUrlPercentEncoded() {
        let raw = "https://oss-links.guoguo.org.cn/医手遮天/第01集.mp3"
        // iOS 17+ / swift-foundation：URL(string:) 默认 lenient，自动百分号编码非法字符
        let url = URL(string: raw)
        XCTAssertNotNil(url)
        let normalized = url!.absoluteString
        XCTAssertTrue(normalized.allSatisfy { $0.isASCII })
        XCTAssertEqual(url!.host, "oss-links.guoguo.org.cn")
        // pathComponents 返回的是【解码后】路径段（swift-foundation 行为，源码核实）
        let seg0 = url!.pathComponents.dropFirst().first!
        XCTAssertEqual(seg0, "医手遮天")
        // 编码形态用 path(percentEncoded: true) 断言
        let encodedPath = url!.path(percentEncoded: true)
        XCTAssertTrue(encodedPath.allSatisfy { $0.isASCII })
        XCTAssertEqual(encodedPath, "/%E5%8C%BB%E6%89%8B%E9%81%AE%E5%A4%A9/%E7%AC%AC01%E9%9B%86.mp3")
        // Idempotent
        XCTAssertEqual(URL(string: normalized)!.absoluteString, normalized)
    }

    func testGarbageUrlIsRejected() {
        // build 36 返修（CI #3）：原 5 条断言全部是对系统 URL(string:) 内部解析行为的
        // 平台断言（lenient 自动编码、encodingInvalidCharacters 严格模式），其中一条在
        // CI 的 iOS 18.5 运行时上不成立（两轮 0.003s/0.005s 秒败=确定性断言失败）。
        // 系统解析器行为非应用契约，改为只断言 PlayUri 自身契约：
        // 1) build 产物必须可解析且三字段回读一致（生产 loadCurrentChapter 依赖）；
        // 2) parse 对空串/垃圾串/缺参串/非数字参数一律拒绝。
        let uri = PlayUri.build(src: "tingyou", albumId: 12345, chapterIdx: 7)
        XCTAssertNotNil(URL(string: uri), "build 产物必须是可解析 URI（生产 resourceLoader 依赖）")
        let parsed = PlayUri.parse(uri)
        XCTAssertEqual(parsed?.src, "tingyou")
        XCTAssertEqual(parsed?.albumId, 12345)
        XCTAssertEqual(parsed?.chapterIdx, 7)
        XCTAssertNil(PlayUri.parse(""), "空串必须被拒绝")
        XCTAssertNil(PlayUri.parse("not a url"), "非 URI 垃圾串必须被拒绝")
        XCTAssertNil(PlayUri.parse("://no-scheme"), "无 scheme 串必须被拒绝")
        XCTAssertNil(PlayUri.parse("tingyou-chapter://play"), "缺全部参数必须被拒绝")
        XCTAssertNil(PlayUri.parse("tingyou-chapter://play?src=tingyou"), "缺 album_id/chapter_idx 必须被拒绝")
        XCTAssertNil(PlayUri.parse("tingyou-chapter://play?src=tingyou&album_id=abc&chapter_idx=1"), "非数字参数必须被拒绝")
    }
}
