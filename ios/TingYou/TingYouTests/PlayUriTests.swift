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
        // iOS 17 Foundation URL parser percent-encodes non-ASCII automatically
        guard let url = URL(string: raw) else {
            // strict parser rejects: percent-encode then retry
            let enc = raw.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "://.")))!
            let url2 = URL(string: enc)
            XCTAssertNotNil(url2)
            XCTAssertEqual(url2?.host, "oss-links.guoguo.org.cn")
            return
        }
        XCTAssertEqual(url.host, "oss-links.guoguo.org.cn")
        // Serialized form must be ASCII-only
        let normalized = url.absoluteString
        XCTAssertTrue(normalized.allSatisfy { $0.isASCII })
        // Idempotent re-parse
        XCTAssertEqual(URL(string: normalized)!.absoluteString, normalized)
    }

    func testGarbageUrlIsRejected() {
        XCTAssertNil(URL(string: ""))
        XCTAssertNil(URL(string: "not a url"))
        XCTAssertNil(URL(string: "http://exa mple.com"))
    }
}
