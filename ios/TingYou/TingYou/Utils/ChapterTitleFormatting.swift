import Foundation

/// UI 增强 · 章节标题序号识别（对齐 abts `_ownIndex` 正则）。
/// 分 P 标题若自带序号（「第3集」「P2」「5.」「3、」等），UI 不应再叠加
/// `ch.index.` 前缀，否则 B 站分 P 会出现「0. P1 绪论」双重编号。
enum ChapterTitleFormatting {
    /// 标题是否自带序号。覆盖：中文数字章集回话期节、P 前缀、阿拉伯数字 + 分隔符、
    /// 阿拉伯数字后接空白与非数字字符。等价于 abts RegExp `_ownIndex`。
    private static let ownIndexPattern = "^\\s*(?:第\\s*[0-9一二三四五六七八九十百千零两]+\\s*[章集回话期节]"
        + "|[Pp]\\s*[0-9]{1,4}\\b"
        + "|[0-9]{1,4}\\s*[.·、:：)\\-—]"
        + "|[0-9]{1,4}(?=\\s*[^0-9]))"

    static func hasOwnIndex(_ title: String) -> Bool {
        title.range(of: ownIndexPattern, options: .regularExpression) != nil
    }
}
