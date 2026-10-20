import Foundation

/// 书架恢复播放的队列重建（build 20 必修 2）：
/// 旧实现给 playQueue 传单章数组，恢复后上/下一章失效，需重开专辑。
/// 现改为：用历史记录里的 src/albumId/detailPath 重新拉取完整章节列表入队；
/// 拉取失败降级为旧行为（仅当前单章）并打日志，不打断恢复。
/// 拆成独立纯组件便于单测注入假 fetch（成功/失败/空列表三条路径）。
struct HistoryResumePlanner: Sendable {
    /// fetch 失败或拿不到路由（预览态）时走降级分支的错误类型。
    struct FetchUnavailableError: Error {}

    enum ResumeOutcome {
        /// 完整队列：全部章节 + 定位到的起始下标（chapters 数组位置，0 基）。
        case fullQueue(chapters: [Chapter], startIdx: Int)
        /// 降级：仅当前单章（拉取失败 / 返回空列表）。
        case singleChapter(Chapter)
    }

    let fetchChapters: @Sendable (_ src: String, _ albumId: Int64, _ detailPath: String?) async throws -> [Chapter]

    func plan(src: String, albumId: Int64, detailPath: String?,
              chapterIdx: Int, chapterTitle: String) async -> ResumeOutcome {
        let fallback = Chapter(chapterId: Int64(chapterIdx), index: chapterIdx,
                               title: chapterTitle, durationSec: nil)
        let fetched: [Chapter]
        do {
            fetched = try await fetchChapters(src, albumId, detailPath)
        } catch {
            // 降级不打断恢复：历史里 src/detailPath 过期、源下线等场景仍能单章续播
            print("resumeHistory: fetch chapters failed [\(src)|\(albumId)]: \(error) —— 降级单章播放")
            return .singleChapter(fallback)
        }
        guard !fetched.isEmpty else {
            print("resumeHistory: chapters empty [\(src)|\(albumId)] —— 降级单章播放")
            return .singleChapter(fallback)
        }
        return .fullQueue(chapters: fetched, startIdx: Self.locate(chapterIdx: chapterIdx, chapterTitle: chapterTitle, in: fetched))
    }

    /// 定位起始章节（数组位置）：index 精确匹配 → chapterId 匹配 → 标题匹配 → 夹取到有效范围。
    static func locate(chapterIdx: Int, chapterTitle: String, in chapters: [Chapter]) -> Int {
        if let i = chapters.firstIndex(where: { $0.index == chapterIdx }) { return i }
        if let i = chapters.firstIndex(where: { $0.chapterId == Int64(chapterIdx) }) { return i }
        if let i = chapters.firstIndex(where: { $0.title == chapterTitle && !chapterTitle.isEmpty }) { return i }
        return min(max(0, chapterIdx - 1), chapters.count - 1)
    }
}
