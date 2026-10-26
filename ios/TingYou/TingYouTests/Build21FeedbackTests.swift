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

    /// build 37 · 反馈 1：ting15 下架（SourceRegistry.ting15 删除）——以本地构造的
    /// 同形态 config（原黄金值）继续守护 MsrcHtml 解析（同 build 36 ting08 样板）。
    private func ting15Cfg() -> SourceRegistry.MsrcSourceConfig {
        SourceRegistry.MsrcSourceConfig(
            id: "ting15", name: "听十五",
            siteBase: "https://m.ting15.com", referer: "https://m.ting15.com/",
            searchPOST: false, extraLHeader: false,
            searchStart: "class=\"clist\"", searchEnd: "class=\"cpage\"",
            fetchHosts: ["m.ting15.com"],
            imgHosts: ["img-book-oss.guoguo.org.cn", "img-south-oss.guoguo.org.cn"],
            audioExact: ["oss-links.guoguo.org.cn", "cloud.guoguo.org.cn"],
            audioSuffixes: [".guoguo.org.cn"]
        )
    }

    func testDecodeNamedEntities() {
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("斗罗大陆&amp;完美世界"), "斗罗大陆&完美世界")
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("书名&quot;引号&quot;"), "书名\"引号\"")
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("A&nbsp;B"), "A B")
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("x&lt;y&gt;z"), "x<y>z")
    }

    // build 36 返修（r4 · CI 失败 2 拆分取证）：原 testDecodeNumericEntities 是全套件
    // 唯一覆盖「十进制」数字实体的用例（其余全过的实体用例——testDecodeMixedNamedAndNumeric
    // 与 testParseSearchDecodesEntitiesAtExit——只用十六进制），NSRegularExpression 旧实现与
    // Swift Regex 新实现两套完全不同的实现挂在同一用例（0.211s/0.251s/1.165s），指向断言侧
    // 或十进制变体的共性因素。CI 并行测试模式下断言消息不进 test.log、xcresult 未上传、
    // 无诊断可用——按拆分取证方案拆成 hex / decimal / 混合三条独立用例，期望值改用
    // Unicode.Scalar 码点构造（本轮已 od -tx1 逐字节核验三行输入与期望字面量均为纯
    // ASCII + 合法 UTF-8、无隐形字符，码点构造再排除字面量编码残余疑点）。下轮 CI 失败
    // 清单将直接指认挂在哪个变体、哪条断言上。
    private var codepointZhongWen: String {
        String(Unicode.Scalar(0x4E2D)!) + String(Unicode.Scalar(0x6587)!)
    }

    func testDecodeNumericHexEntities() {
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("&#x4E2D;&#x6587;"), codepointZhongWen,
                       "十六进制数字实体：&#x4E2D;(U+4E2D 中) + &#x6587;(U+6587 文)")
    }

    func testDecodeNumericDecimalEntities() {
        // 0x4E2D = 20013、0x6587 = 25991（十进制码点）
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("&#20013;&#25991;"), codepointZhongWen,
                       "十进制数字实体：&#20013;=中 &#25991;=文（全套件唯一十进制覆盖）")
    }

    func testDecodeNumericHexDecimalMixed() {
        XCTAssertEqual(MsrcHtml.decodeHTMLEntities("&#x4E2D;&#25991;"), codepointZhongWen,
                       "十六/十进制混合：hex 中 + decimal 文（build 37：原输入第二项 &#20013;＝中系 test-side typo，已改 &#25991;＝文）")
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
        let items = MsrcHtml.parseSearch(cfg: ting15Cfg(), html: html)
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
