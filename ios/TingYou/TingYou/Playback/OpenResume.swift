import Foundation

/// build 54 · 需求 a/b/c/d/e：打开书（书架收藏 / 历史）时的历史进度定位——纯逻辑层。
///
/// 三条硬约束（全部来自验收口径）：
/// 1. **数据源 = 合并后的本地真相**。云端较新的进度由 `SyncEngine.merge` 按
///    `updated_at` LWW 写入 SwiftData（云端较新才覆盖本地），本层只消费
///    `HistoryModel` 映射出的 `HistorySnapshot`，**不直连云**——不绕过 SyncEngine
///    自行拉云。
/// 2. **章号口径 = 源原生章号**（`Chapter.index`：tingyou 1 基，bili / 易听书 0 基）。
///    云端 0 基 ↔ 本地源基底的换算已在同步出入口经 `ChapterIdxNormalization`
///    完成（build 51 P0-1），本层不再二次换算，避免双重偏移。
/// 3. **通道位置语义必须显式**：恢复 / 定位链路一律走
///    `PlaybackManager.ChapterStart.arrayPosition`。b36 的「先按 index 值猜一次」
///    在 1 基源（听友FM）上会早一章（见 PlaybackManager.ChapterStart 注释）。
struct HistorySnapshot: Equatable, Sendable {
    let src: String
    let albumId: Int64
    /// 源原生章号（与 `Chapter.index` 同口径）
    let chapterIdx: Int
    let chapterTitle: String
    let positionMs: Int64
    let durationMs: Int64
    let updatedAt: Int64
    let detailPath: String?

    init(src: String, albumId: Int64, chapterIdx: Int, chapterTitle: String,
         positionMs: Int64, durationMs: Int64, updatedAt: Int64, detailPath: String? = nil) {
        self.src = src
        self.albumId = albumId
        self.chapterIdx = chapterIdx
        self.chapterTitle = chapterTitle
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.updatedAt = updatedAt
        self.detailPath = detailPath
    }

    init(_ h: HistoryModel) {
        self.init(src: h.src, albumId: h.albumId, chapterIdx: h.chapterIdx,
                  chapterTitle: h.chapterTitle, positionMs: h.positionMs,
                  durationMs: h.durationMs, updatedAt: h.updatedAt,
                  detailPath: h.detailPath)
    }
}

/// 定位目标（章号为源原生章号）。
struct ResumeTarget: Equatable, Sendable {
    let chapterIdx: Int
    let chapterTitle: String
    let positionMs: Int64
    let durationMs: Int64
}

/// 播放器当前装载态的最小快照（「打开书要不要切换装载」的纯决策输入）。
struct QueueAnchor: Equatable, Sendable {
    let src: String
    let albumId: Int64
    /// 当前章在**章节数组**里的位置；未装载 / 越界时为 nil
    let arrayPosition: Int?
}

/// 打开书定位的完整结论：视图层照单执行，不再自己算。
struct OpenResumePlan: Equatable, Sendable {
    let target: ResumeTarget
    /// 目标章节对象（滚动定位 / 高亮用）
    let chapter: Chapter
    /// 目标章在章节数组中的位置（0 基）
    let arrayPosition: Int
    /// 已按章节时长夹取的起播位置（毫秒）
    let startPosMs: Int64
    /// 是否要把播放器静默装载到该书目标章
    let shouldPrepare: Bool
}

enum OpenResumePlanner {

    /// 同一本书理论上只有一条历史（`AlbumRepository.recordHistory` 按 (src, albumId)
    /// upsert），但跨端合并 / 历史遗留可能留多条——取 `updatedAt` 最新者，
    /// 与同步 LWW 口径一致。无记录返回 nil（需求 d：新书 / 清过数据的书行为不变）。
    static func target(src: String, albumId: Int64,
                       in snapshots: [HistorySnapshot]) -> ResumeTarget? {
        let candidates = snapshots.filter { $0.src == src && $0.albumId == albumId }
        guard let newest = candidates.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        return ResumeTarget(chapterIdx: newest.chapterIdx,
                            chapterTitle: newest.chapterTitle,
                            positionMs: max(0, newest.positionMs),
                            durationMs: max(0, newest.durationMs))
    }

    /// 目标章在章节列表中的位置（0 基）。列表为空 → nil（不定位、不越界）。
    /// 复用 `HistoryResumePlanner.locate`（index → chapterId → 标题 → 夹取），
    /// 不另立一套定位规则。
    static func arrayPosition(for target: ResumeTarget, in chapters: [Chapter]) -> Int? {
        guard !chapters.isEmpty else { return nil }
        return HistoryResumePlanner.locate(chapterIdx: target.chapterIdx,
                                          chapterTitle: target.chapterTitle,
                                          in: chapters)
    }

    /// 需求 c/e：历史 position 与「当前源该章时长」不一致时夹取到有效范围。
    ///
    /// 章时长未知（bili / 易听书章节无 durationSec）时只保证非负，由
    /// `PlaybackManager` 运行期按真实 `durationMs` 再夹一次。
    ///
    /// 越界时**留 1 秒余量**（`endMarginMs`）而不是夹到正好等于时长：夹到章尾会
    /// 立刻触发 `onChapterFinished` 自动跳下一章，观感是「打开就自己跳章」，
    /// 比少播 1 秒更糟。
    static let endMarginMs: Int64 = 1000

    static func clampPosition(_ positionMs: Int64, chapterDurationSec: Int?) -> Int64 {
        guard positionMs > 0 else { return 0 }
        guard let sec = chapterDurationSec, sec > 0 else { return positionMs }
        let durMs = Int64(sec) * 1000
        guard positionMs >= durMs else { return positionMs }
        return max(0, durMs - endMarginMs)
    }

    /// 打开书是否要把播放器静默装载到目标章（需求 e：到位即静默，不制造声音闪断）。
    /// - 正在播放任何一本 → 不动播放器（打开详情页不得打断正在听的音频；
    ///   用户点「继续收听」/ 点该章时才切换，切换本身带历史位置）；
    /// - 已装载本书且正停在目标章 → 不重复装载（避免重新取流 + 重写历史）；
    /// - 其余（空闲 / 停在别的书 / 本书停在别的章）→ 静默装载到目标章。
    static func shouldPrepare(anchor: QueueAnchor?, isPlaying: Bool,
                              album: Album, target: ResumeTarget,
                              chapters: [Chapter]) -> Bool {
        if isPlaying { return false }
        guard let anchor,
              anchor.src == album.source, anchor.albumId == album.albumId,
              let pos = anchor.arrayPosition, chapters.indices.contains(pos),
              chapters[pos].index == target.chapterIdx else { return true }
        return false
    }

    /// 由目标 + 章节列表产出完整定位结论（所有分支共用的唯一构造点）。
    static func plan(target: ResumeTarget?, album: Album, chapters: [Chapter],
                     anchor: QueueAnchor?, isPlaying: Bool) -> OpenResumePlan? {
        guard let target,
              let pos = arrayPosition(for: target, in: chapters),
              chapters.indices.contains(pos) else { return nil }
        let chapter = chapters[pos]
        let startPosMs = clampPosition(target.positionMs, chapterDurationSec: chapter.durationSec)
        let shouldPrepare = Self.shouldPrepare(anchor: anchor, isPlaying: isPlaying,
                                              album: album, target: target, chapters: chapters)
        return OpenResumePlan(target: target, chapter: chapter, arrayPosition: pos,
                              startPosMs: startPosMs, shouldPrepare: shouldPrepare)
    }

    /// 打开详情页用：从本地历史集合取本书最新一条。
    static func plan(album: Album, chapters: [Chapter], snapshots: [HistorySnapshot],
                     anchor: QueueAnchor?, isPlaying: Bool) -> OpenResumePlan? {
        plan(target: target(src: album.source, albumId: album.albumId, in: snapshots),
             album: album, chapters: chapters, anchor: anchor, isPlaying: isPlaying)
    }

    /// 书架历史条目 / 启动恢复用：手上只有单条历史（`HistoryModel`）。
    static func plan(album: Album, chapters: [Chapter], snapshot: HistorySnapshot?,
                     anchor: QueueAnchor?, isPlaying: Bool) -> OpenResumePlan? {
        plan(target: snapshot.map { ResumeTarget(chapterIdx: $0.chapterIdx,
                                                 chapterTitle: $0.chapterTitle,
                                                 positionMs: max(0, $0.positionMs),
                                                 durationMs: max(0, $0.durationMs)) },
             album: album, chapters: chapters, anchor: anchor, isPlaying: isPlaying)
    }
}
