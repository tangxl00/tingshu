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
        // iOS 17+ / swift-foundation：默认 lenient（encodingInvalidCharacters: true），
        // “not a url” 的空格会被自动编码而不返回 nil；严格拒绝垃圾串须显式传 false。
        // 注：harness://no-slash 的 host “no-slash” 是合法 reg_name（含 -），属合法 URL。
        XCTAssertNotNil(URL(string: "not a url"))
        XCTAssertNil(URL(string: "not a url", encodingInvalidCharacters: false))
        XCTAssertNil(URL(string: ""))
        XCTAssertNil(URL(string: "://no-scheme", encodingInvalidCharacters: false))
        XCTAssertNil(URL(string: "http://exa mple.com/x", encodingInvalidCharacters: false))
    }
}
