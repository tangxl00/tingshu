import XCTest
@testable import TingYou

/// build 21 · 反馈 1：播放模式决策与持久化。
/// 判别力：build 20 无任何播放模式逻辑（onChapterFinished 无条件 nextChapter，
/// 到尾即 guard return）——旧实现下 chapterFinishedAction 不存在、这些测试无法通过。
final class PlayModeTests: XCTestCase {

    // MARK: - 章节播完决策（纯函数）

    func testSequenceAdvancesInMiddle() {
        XCTAssertEqual(PlaybackManager.chapterFinishedAction(playMode: .sequence, currentIdx: 2, chapterCount: 10), .advance)
    }

    func testSequenceStopsAtEnd() {
        // 旧行为：到尾即停（保持一致）
        XCTAssertEqual(PlaybackManager.chapterFinishedAction(playMode: .sequence, currentIdx: 9, chapterCount: 10), .stop)
    }

    func testSequenceSingleChapterListStops() {
        XCTAssertEqual(PlaybackManager.chapterFinishedAction(playMode: .sequence, currentIdx: 0, chapterCount: 1), .stop)
    }

    func testRepeatOneAlwaysReplaysCurrent() {
        XCTAssertEqual(PlaybackManager.chapterFinishedAction(playMode: .repeatOne, currentIdx: 0, chapterCount: 1), .replayCurrent)
        XCTAssertEqual(PlaybackManager.chapterFinishedAction(playMode: .repeatOne, currentIdx: 5, chapterCount: 10), .replayCurrent)
        XCTAssertEqual(PlaybackManager.chapterFinishedAction(playMode: .repeatOne, currentIdx: 9, chapterCount: 10), .replayCurrent)
    }

    func testRepeatAllWrapsAtEnd() {
        XCTAssertEqual(PlaybackManager.chapterFinishedAction(playMode: .repeatAll, currentIdx: 9, chapterCount: 10), .wrapToFirst)
    }

    func testRepeatAllAdvancesInMiddle() {
        XCTAssertEqual(PlaybackManager.chapterFinishedAction(playMode: .repeatAll, currentIdx: 3, chapterCount: 10), .advance)
    }

    // MARK: - 持久化接线

    func testSetPlayModePersistsToUserDefaults() {
        let pm = PlaybackManager(playbackRepository: nil)
        defer { pm.setPlayMode(.sequence) } // 还原默认，避免污染其他测试
        XCTAssertEqual(pm.playMode, .sequence, "未设置时默认顺序播放")
        pm.setPlayMode(.repeatOne)
        XCTAssertEqual(pm.playMode, .repeatOne)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "play_mode"), PlayMode.repeatOne.rawValue)
    }

    func testPlayModeDisplayNameUnique() {
        let names = Set(PlayMode.allCases.map(\.displayName))
        XCTAssertEqual(names.count, PlayMode.allCases.count, "三档模式显示名不得重复")
    }
}

/// build 21 · 反馈 2（Bug B）：HTML 实体解码。
/// 判别力：build 20 stripTags 只删标签不还原实体（&amp; 原样透出）——
/// 出口未套 decodeHTMLEntities 前这些断言必然失败。
final class HtmlEntityTests: XCTestCase {

    func testDecodeNamedEntities() {
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("斗罗大陆&amp;完美世界"), "斗罗大陆&完美世界")
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("书名&quot;引号&quot;"), "书名\"引号\"")
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("A&nbsp;B"), "A B")
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("x&lt;y&gt;z"), "x<y>z")
    }

    func testDecodeNumericEntities() {
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("&#x4E2D;&#x6587;"), "中文")
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("&#20013;&#25991;"), "中文")
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("&#x4E2D;&#20013;"), "中文") // 十六/十进制混合
    }

    func testDecodeMixedNamedAndNumeric() {
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("&#x4E2D;&amp;&#x6587;"), "中&文")
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("完美&#x4E16;&#x754C;&quot;名&quot;"), "完美世界\"名\"")
    }

    func testDecodeSingleLayerSemantics() {
        // &amp;#x4E2D; 解为字面 &#x4E2D;（与浏览器一层语义一致，不做递归解码）
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("&amp;#x4E2D;"), "&#x4E2D;")
    }

    func testUnknownEntityPreserved() {
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("&unknown;"), "&unknown;")
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("无实体文本"), "无实体文本")
    }

    func testParseSearchDecodesEntitiesAtExit() {
        // parseSearch 出口统一实体还原（真实站点搜索/分类页会出现转义书名）
        let html = """
        <html><body><div class="clist">
        <a href="/youshengxiaoshuo/1001.html"><dl><dt><img src="https://img.ting15.com/1001.jpg"/><h3>&#x6597;&#x7F57;&#22823;&#38470;&amp;&#x5B8C;&#x7F8E;&#x4E16;&#x754C;</h3><dd><p>作者：&#21776;&#23478;&#19977;&#23569;</p><p>播音：小C</p></dd></dl></a>
        </div><div class="cpage"></div></body></html>
        """
        let items = MsrcHtml.parseSearch(cfg: SourceRegistry.ting15, html: html)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "斗罗大陆&完美世界")
        XCTAssertEqual(items[0].author, "唐家三少")
    }
}

/// build 21 · 反馈 2（Bug B）：响应体 charset 探测解码。
/// 判别力：build 20 fetchHTML 的 `String(data:,encoding:.utf8) ?? ""` 对 GBK 字节流
/// 返回空串——decodeBody 在旧实现下不存在、GBK 样本断言必然失败。
final class CharsetDecodeTests: XCTestCase {

    /// "中文测试" 的 GBK（gb2312 兼容）字节黄金样本
    private let gbkData: [UInt8] = [0xD6, 0xD0, 0xCE, 0xC4, 0xB2, 0xE2, 0xCA, 0xD4]

    func testDeclaredGb18030CharsetDecodes() {
        let s = APIClient.decodeBody(Data(gbkData), contentType: "text/html; charset=gb2312")
        XCTAssertEqual(s, "中文测试")
    }

    func testUndeclaredGbkFallsBackToGb18030() {
        // 未声明 charset 的 GBK 老站：utf-8 解码失败 → gb18030 探测成功
        let s = APIClient.decodeBody(Data(gbkData), contentType: "text/html")
        XCTAssertEqual(s, "中文测试", "utf-8 失败后应探测 gb18030 而不是返回空串")
    }

    func testUtf8StillWorks() {
        let data = "中文测试".data(using: .utf8)!
        XCTAssertEqual(APIClient.decodeBody(data, contentType: "text/html; charset=utf-8"), "中文测试")
        XCTAssertEqual(APIClient.decodeBody(data, contentType: nil), "中文测试")
    }

    func testUnknownCharsetNameFallsBackToDetection() {
        // 声明了未知 charset 名 → 忽略声明走探测链
        let data = "中文".data(using: .utf8)!
        let s = APIClient.decodeBody(data, contentType: "text/html; charset=weird-unknown-8")
        XCTAssertEqual(s, "中文")
    }

    func testLatin1FallbackNeverReturnsEmpty() {
        // 无任何编码可解（含非法序列）→ ISO-8859-1 兜底不空（可显示乱码但不丢数据）
        let s = APIClient.decodeBody(Data([0xFF, 0xFE, 0x81]), contentType: nil)
        XCTAssertFalse(s.isEmpty)
    }

    func testCharsetParsingCaseInsensitive() {
        let s = APIClient.decodeBody(Data(gbkData), contentType: "TEXT/HTML; CHARSET=GBK")
        XCTAssertEqual(s, "中文测试")
    }
}
