import Foundation

/// build 51 · P0-1（质检 NO-GO 必修）：chapter_idx 基底归一化唯一出口。
///
/// 背景（质检逐章复算 N=6 实证）：
/// - 云端契约（契约 v1.0.0 §progress）的 `chapter_idx` 是 **0 基**（章节数组位置）；
/// - 本地 `Chapter.index` 是 **源原生章号**，基底随源不同：
///   * tingyou（听友FM）：API `chapters/{id}` 的 `index` 从 1 开始
///     （单测 `testChaptersIndexStartsAtOne` 锁定，实测 chapters/1255949196 = 1,2,3…）；
///   * bili / yitingshu：`SourceRouter.chapters` 用 `page - 1`，从 0 开始。
///
/// 未归一化的后果（双向错章）：
/// - iOS → PC：本地第 k 章（1 基）原样写 `chapter_idx = k`，PC 按 0 基取 → 落第 k+1 章（晚一章）；
/// - PC → iOS：PC 合规写 `k-1`，`HistoryResumePlanner.locate` 在 1 基表精确匹配 `k-1`
///   → 数组位置 `k-2` → 落第 k-1 章（早一章）。仅 k=1 恰好无偏移，
///   k≥2 一次往返错开两章，跨设备续播在主力源不可用。
///
/// 因此**所有**进出云端的 chapterIdx 都必须经本枚举换算（入队 = toCloud，
/// 回传落库 = toLocal），不得在任何出口直接透传 `chapter.index`。
enum ChapterIdxNormalization {

    /// 本地源原生章号 → 云端 0 基章号。
    /// tingyou 1 基减 1；bili / 易听书本身 0 基原样透传。
    static func toCloud(src: String, localIndex: Int) -> Int {
        src == SourceRegistry.TINGYOU ? localIndex - 1 : localIndex
    }

    /// 云端 0 基章号 → 本地源原生章号（toCloud 的逆运算）。
    static func toLocal(src: String, cloudIdx: Int) -> Int {
        src == SourceRegistry.TINGYOU ? cloudIdx + 1 : cloudIdx
    }

    /// 该源的本地章号是否 1 基（UI 展示与云端换算共用同一判据）。
    static func isOneBased(src: String) -> Bool {
        src == SourceRegistry.TINGYOU
    }

    /// 章节数组位置（0 基）→ 本地源原生章号（用于把播放队列下标换算回 Chapter.index）。
    static func fromArrayPosition(src: String, position: Int) -> Int {
        isOneBased(src: src) ? position + 1 : position
    }

    /// 本地源原生章号 → 章节数组位置（0 基）。
    static func toArrayPosition(src: String, localIndex: Int) -> Int {
        isOneBased(src: src) ? localIndex - 1 : localIndex
    }
}
