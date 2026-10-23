import Foundation

// build 29 · 59听书网播放页解析器（架构师核实方案，设计文档 10.7.1）。
// 播放页（/play/{书ID}-{线路}-{序号}.html）inline script 明文暴露音频直链：
// var now="http://audio.xmcdn.com/...m4a";——无签名、无 token、无时效，始终动态提取。
// 两条硬约束：
// 1. http → https 升级：站点直链为 http:// 明文，NSC 全局禁明文——提取后统一升级 https://；
// 2. 出站域白名单兜底：升级后的 URL host 必须在 Ting59Source.HOST_SUFFIXES 内。

enum Ting59PlayParser {
    private static let nowRe = try! NSRegularExpression(
        pattern: #"var\s+now\s*=\s*"([^"]+)""#,
        options: []
    )

    static func extractAudioUrl(html: String) throws -> String {
        let range = NSRange(html.startIndex..., in: html)
        guard let match = nowRe.firstMatch(in: html, options: [], range: range),
              let urlRange = Range(match.range(at: 1), in: html) else {
            throw URLError(.badServerResponse)
        }
        let raw = String(html[urlRange]).trimmingCharacters(in: .whitespaces)
        let upgraded = upgradeToHttps(raw)
        guard let host = URL(string: upgraded)?.host,
              Ting59Source.hostAllowed(host) else {
            throw URLError(.badServerResponse)
        }
        return upgraded
    }

    private static func upgradeToHttps(_ raw: String) -> String {
        if raw.hasPrefix("https://") { return raw }
        if raw.hasPrefix("http://") { return "https://" + raw.dropFirst(7) }
        if raw.hasPrefix("//") { return "https:" + raw }
        return raw
    }
}
