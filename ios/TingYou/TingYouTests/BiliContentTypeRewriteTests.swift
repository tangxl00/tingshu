import XCTest
@testable import TingYou

/// build 47 · 真机取证闭环（B站 octet-stream）：B站 CDN 镜像节点对 DASH 音轨回
/// Content-Type: application/octet-stream（真机证据 2026-10-28：play · HTTP 206
/// application/octet-stream @ upos-sz-mirrorbd.bilivideo.com），AVPlayer 的
/// contentInformationRequest 拿到 octet-stream 按不支持格式拒收 → -12847。
/// 沙箱出口拿到的是 video/mp4（云端绿真机红的分水岭；沙箱无法复现
/// octet-stream 形态，改写正确性由本组单测 + 真机 [诊断] 截图闭环）。
/// 锁定 rewrittenBiliContentType 与 sniffedBiliMp4Mime 的改写逻辑：
/// B站代理域 octet-stream 按路径/ftyp 嗅探映射 mp4；非 B站域与已正确类型
/// 一律不改写。
final class BiliContentTypeRewriteTests: XCTestCase {

    // MARK: - 响应期路径改写（rewrittenBiliContentType）

    func testOctetStreamOnBiliCdnM4sPathRewritesToAudioMp4() {
        // B站 DASH 音轨直链路径形如 /upgcxcode/.../xx-1-30280.m4s（30280=64k 音轨，
        // 30232=132k，30216=Dolby EC-3 已被 codec 过滤排除）
        for host in ["upos-sz-mirrorbd.bilivideo.com", "bilivideo.com",
                     "upos-sz-mirrorcoso1.bilivideo.com", "cdn.example.akamaized.net",
                     "i0.hdslb.com"] {
            let url = URL(string: "https://\(host)/upgcxcode/12/34/5678-1-30280.m4s?e=2026&os=upos&trid=xx")
            XCTAssertEqual(
                PlaybackManager.rewrittenBiliContentType(originalMime: "application/octet-stream", url: url),
                "audio/mp4",
                "\(host) 的 .m4s octet-stream 必须改写为 audio/mp4（-12847 根因修复）")
        }
    }

    func testOctetStreamOnNonBiliHostIsNotRewritten() {
        // 非 B站代理域（其余音源/API）不越权重写——octet-stream 属上游行为，
        // 改写只针对真机取证确认的 B站 CDN 镜像节点
        for host in ["tingyou.fm", "www.ting15.com", "api.bilibili.com", "www.bilibili.com"] {
            let url = URL(string: "https://\(host)/audio/abc.m4s")
            XCTAssertEqual(
                PlaybackManager.rewrittenBiliContentType(originalMime: "application/octet-stream", url: url),
                "application/octet-stream",
                "\(host) 非代理 CDN 域不得改写 Content-Type")
        }
    }

    func testCorrectMimeIsNeverRewritten() {
        // 已是正常媒体类型（沙箱出口实测 video/mp4）——原样透传
        let url = URL(string: "https://upos-sz-mirrorbd.bilivideo.com/upgcxcode/xx/yy/zz-1-30280.m4s")
        XCTAssertEqual(
            PlaybackManager.rewrittenBiliContentType(originalMime: "video/mp4", url: url),
            "video/mp4", "非 octet-stream 不得改写")
        XCTAssertEqual(
            PlaybackManager.rewrittenBiliContentType(originalMime: "audio/mp4", url: url),
            "audio/mp4", "audio/mp4 原样透传")
        XCTAssertNil(
            PlaybackManager.rewrittenBiliContentType(originalMime: nil, url: url),
            "无 Content-Type 保持 nil（交由 AVFoundation 默认行为）")
    }

    func testOctetStreamMp4PathRewritesToVideoMp4() {
        let url = URL(string: "https://upos-sz-mirrorbd.bilivideo.com/upgcxcode/12/34/zz.mp4?x=1")
        XCTAssertEqual(
            PlaybackManager.rewrittenBiliContentType(originalMime: "application/octet-stream", url: url),
            "video/mp4", ".mp4 路径 octet-stream 改写为 video/mp4")
    }

    func testOctetStreamWithoutPathHintDefersToSniff() {
        // B站域但路径无扩展名线索：响应期不得盲改写（返回原值），挂起等
        // 首块 ftyp 嗅探（ProxyStreamSessionDelegate.didReceive data）
        let url = URL(string: "https://upos-sz-mirrorbd.bilivideo.com/?dl=1&os=upos")
        XCTAssertEqual(
            PlaybackManager.rewrittenBiliContentType(originalMime: "application/octet-stream", url: url),
            "application/octet-stream",
            "无路径线索时响应期不得盲改写（由 sniffedBiliMp4Mime 兜底）")
    }

    // MARK: - 首块数据 ftyp 嗅探（sniffedBiliMp4Mime）

    /// fMP4 头样例：4 字节盒长（0x18=24）+ "ftyp" + major brand "iso5"
    private let fmp4Header = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypiso5".utf8)

    func testSniffFtypAtStreamStartYieldsAudioMp4() {
        XCTAssertEqual(
            PlaybackManager.sniffedBiliMp4Mime(data: fmp4Header, streamOffset: 0),
            "audio/mp4",
            "流首 4..<8 为 ftyp 盒标签即判 fMP4 音轨（B站 DASH 音轨分段）")
    }

    func testSniffFtypInsideLaterChunkStillDetected() {
        // 206 响应自流内偏移 2 起的块（Content-Range bytes 2-..）：ftyp 标签在
        // 块内下标 2（= 流内 4..<8），按流内偏移换算嗅探
        let chunk = Data([0xAB, 0xCD]) + Data("ftypiso5".utf8)
        XCTAssertEqual(
            PlaybackManager.sniffedBiliMp4Mime(data: chunk, streamOffset: 2),
            "audio/mp4",
            "覆盖流内偏移 4..<8 的块也应嗅探到 ftyp（按流内偏移换算，非块内 0）")
    }

    func testSniffNonMp4OrTooShortOrOutOfRangeReturnsNil() {
        XCTAssertNil(
            PlaybackManager.sniffedBiliMp4Mime(data: Data("mp3data!".utf8), streamOffset: 0),
            "非 fMP4 流（4..<8 非 ftyp 标签）不得嗅探出 mp4")
        XCTAssertNil(
            PlaybackManager.sniffedBiliMp4Mime(data: Data([0x00, 0x00]), streamOffset: 0),
            "不足以覆盖流内偏移 4..<8 的短块（如探测请求 0-1）返回 nil 等后续块")
        XCTAssertNil(
            PlaybackManager.sniffedBiliMp4Mime(data: fmp4Header, streamOffset: 36),
            "块起点已越过 ftyp 位置的（如 moov 段请求自 36 起）不得误判")
        XCTAssertNil(
            PlaybackManager.sniffedBiliMp4Mime(data: Data(), streamOffset: -1),
            "非法偏移返回 nil 不崩溃")
    }
}
