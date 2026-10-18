import Foundation

/// 导入组织器（v1.3.0 需求 3）：纯逻辑，无平台依赖。
/// 移植自安卓版 com.tingyou.app.data.imports.ImportOrganizer。
enum ImportOrganizer {

    struct ImportLink {
        let url: String
        let title: String?
    }

    enum LinkParseResult {
        case ok([ImportLink])
        case rejected(badLines: [String])

        var isOK: Bool {
            if case .ok = self { return true }
            return false
        }
        var links: [ImportLink]? {
            if case .ok(let l) = self { return l }
            return nil
        }
        var badLines: [String]? {
            if case .rejected(let b) = self { return b }
            return nil
        }
    }

    // ---------- ① 自然排序 ----------

    static func naturalCompare(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        var i = 0
        var j = 0
        while i < aChars.count && j < bChars.count {
            let ca = aChars[i]
            let cb = bChars[j]
            if ca.isNumber && cb.isNumber {
                var ai = i
                var bj = j
                while ai < aChars.count && aChars[ai].isNumber { ai += 1 }
                while bj < bChars.count && bChars[bj].isNumber { bj += 1 }
                let aNumStr = String(aChars[i..<ai])
                let bNumStr = String(bChars[j..<bj])
                let na = Int64(aNumStr) ?? 0
                let nb = Int64(bNumStr) ?? 0
                if na != nb { return na < nb ? -1 : 1 }
                if aNumStr != bNumStr { return aNumStr < bNumStr ? -1 : 1 }
                i = ai
                j = bj
            } else {
                if ca != cb { return ca < cb ? -1 : 1 }
                i += 1
                j += 1
            }
        }
        return (aChars.count - i) - (bChars.count - j)
    }

    static func naturalSort(_ items: [String]) -> [String] {
        items.sorted { naturalCompare($0, $1) < 0 }
    }

    // ---------- ②③ 章节标题与书名建议 ----------

    static func chapterTitle(_ displayName: String) -> String {
        if let dot = displayName.lastIndex(of: ".") {
            let stripped = String(displayName[..<dot]).trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? displayName : stripped
        }
        return displayName
    }

    static func suggestBookTitle(_ displayNames: [String]) -> String {
        if displayNames.isEmpty { return "" }
        if displayNames.count == 1 { return chapterTitle(displayNames[0]) }
        var prefix = displayNames[0]
        for n in displayNames.dropFirst() {
            var k = 0
            let lim = min(prefix.count, n.count)
            let pChars = Array(prefix)
            let nChars = Array(n)
            while k < lim && pChars[k] == nChars[k] { k += 1 }
            prefix = String(pChars.prefix(k))
        }
        while true {
            let stripped = stripTrailingNumbering(prefix)
            if stripped == prefix { break }
            prefix = stripped
        }
        let cleaned = prefix.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return cleaned.count >= 2 ? cleaned : chapterTitle(displayNames[0])
    }

    private static let NUMBERING_TOKENS: Set<String> = [
        "第", "回", "卷", "集", "章", "话", "部",
        "ep", "eps", "episode", "track", "chap", "chapter", "part", "cd", "disc", "vol", "no",
    ]

    private static func stripTrailingNumbering(_ p: String) -> String {
        let chars = Array(p)
        var end = chars.count
        while end > 0 && !chars[end - 1].isLetter && !chars[end - 1].isNumber {
            end -= 1
        }
        if end == 0 { return "" }
        var d = end
        while d > 0 && chars[d - 1].isNumber { d -= 1 }
        if d == end {
            // No trailing digits: check if the trailing token is a numbering word
            var te = end
            while te > 0 && chars[te - 1].isLetter { te -= 1 }
            let tailToken = String(chars[te..<end])
            if NUMBERING_TOKENS.contains(tailToken.lowercased()) && te > 0 {
                var ts = te
                while ts > 0 && !chars[ts - 1].isLetter && !chars[ts - 1].isNumber {
                    ts -= 1
                }
                return String(chars.prefix(ts))
            }
            return String(chars.prefix(end))
        }
        var t = d
        while t > 0 && !chars[t - 1].isLetter && !chars[t - 1].isNumber {
            t -= 1
        }
        var tokenStart = t
        while tokenStart > 0 && chars[tokenStart - 1].isLetter { tokenStart -= 1 }
        let token = String(chars[tokenStart..<t])
        if NUMBERING_TOKENS.contains(token.lowercased()) {
            while tokenStart > 0 && !chars[tokenStart - 1].isLetter && !chars[tokenStart - 1].isNumber {
                tokenStart -= 1
            }
            return String(chars.prefix(tokenStart))
        }
        return String(chars.prefix(d))
    }

    // ---------- ④ 在线链接校验（https-only） ----------

    private static func parseHttpsUrl(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return trimmed
    }

    static func parseDirectLinks(_ text: String) -> LinkParseResult {
        var links: [ImportLink] = []
        var bad: [String] = []
        var seen: Set<String> = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let url = parseHttpsUrl(line) {
                if seen.insert(url).inserted {
                    links.append(ImportLink(url: url, title: nil))
                }
            } else {
                bad.append(line)
            }
        }
        return bad.isEmpty ? .ok(links) : .rejected(badLines: bad)
    }

    static func titleFromUrl(_ url: String) -> String? {
        guard let u = URL(string: url) else { return nil }
        let path = u.path
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    static func isM3uUrl(_ url: String) -> Bool {
        guard let u = URL(string: url) else { return false }
        let path = u.path.lowercased()
        return path.hasSuffix(".m3u") || path.hasSuffix(".m3u8")
    }

    static func hostOf(_ url: String) -> String? {
        guard let u = URL(string: url) else { return nil }
        return u.host?.lowercased()
    }

    // ---------- ⑤ m3u 解析 ----------

    static func parseM3u(_ text: String) -> LinkParseResult {
        var links: [ImportLink] = []
        var bad: [String] = []
        var seen: Set<String> = []
        var pendingTitle: String? = nil
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.lowercased().hasPrefix("#extinf:") {
                let after = String(line.dropFirst("#extinf:".count))
                if let comma = after.firstIndex(of: ",") {
                    let title = String(after[after.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                    pendingTitle = title.isEmpty ? nil : title
                } else {
                    pendingTitle = nil
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            if let url = parseHttpsUrl(line) {
                if seen.insert(url).inserted {
                    links.append(ImportLink(url: url, title: pendingTitle))
                }
            } else {
                bad.append(line)
            }
            pendingTitle = nil
        }
        return bad.isEmpty ? .ok(links) : .rejected(badLines: bad)
    }

    // ---------- ⑥ 音频扩展名白名单 ----------

    static func hasAudioExtension(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        for ext in [".mp3", ".m4a", ".m4b", ".flac", ".aac", ".ogg", ".wav", ".opus"] {
            if lower.hasSuffix(ext) { return true }
        }
        return false
    }
}
