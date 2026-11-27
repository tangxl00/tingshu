import SwiftUI
import SwiftData

/// 专辑详情页：章节列表按专辑来源走 SourceRouter 真实路由（P0-3）——
/// tingyou 走 JSON API；
/// 点击章节经 PlaybackManager 播放（占位 URI 由 AVAssetResourceLoaderDelegate 惰性解析直链）。
/// build 45 · 反馈 3：悦听（ytysxs）摘除——AntibotException 拦截文案删除
///（存量 ytysxs 书 chapters 走 default 分支报「源已下架」）。
///
/// build 54 · 需求 a/b/c/d/e（历史进度定位）：打开本书即定位到上次收听——
/// 数据源是**本地历史**（`HistoryModel`），本页只读本地；定位 = 章节列表滚动到该章
/// 并高亮 + 需要时播放器静默装载该章历史位置（不先播第一章再跳）。
/// 无历史保持原行为（需求 d）。
struct AlbumScreen: View {
    let album: Album
    @State private var chapters: [Chapter] = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// build 36 · 反馈 6：章节列表加载完成后是否已自动定位过（只定位一次，切章不抢滚动）
    @State private var didScrollToCurrent = false
    /// build 54：打开本书的历史定位结论（nil = 无历史，需求 d 行为不变）
    @State private var resumePlan: OpenResumePlan?
    /// UI 增强：章节目录正序/倒序（仅展示顺序，不改变播放队列与 chapterIdx 口径）
    @State private var chaptersReversed = false
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var modelContext

    /// UI 增强：章节展示顺序。倒序仅作用于本页 ForEach，playChapter 仍传原 chapters，
    /// 保证播放队列下标与 chapterIdx 口径不变（abts 同为纯展示层顺序切换）。
    private var displayedChapters: [Chapter] {
        chaptersReversed ? chapters.reversed() : chapters
    }

    /// UI 增强：已听章节的位置上界（数组 0 基，不含当前章）。
    /// 数据源为本书历史的最新一条（每书单条 upsert），语义为「当前进度之前的章节视为已听」。
    /// 局限：无法识别跳听（先听第 9 章再回听第 2 章时，第 2~8 章会被误标已听）——
    /// 这是单条历史模型的固有限制，与 abts 逐章 done 记录不等价，需逐章记录落地后升级。
    private var listenedBeforePosition: Int? {
        if let pm = container?.playbackManager,
           pm.currentAlbum?.albumId == album.albumId,
           pm.currentAlbum?.source == album.source,
           pm.currentChapters.indices.contains(pm.currentChapterIdx) {
            return pm.currentChapterIdx
        }
        return resumePlan?.arrayPosition
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            Section {
                HStack(spacing: 12) {
                    CoverImage(url: album.coverUrl, size: 90, source: album.source)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title).font(.headline).lineLimit(2)
                            // build 42 · 任务一：专辑页特征元素标识——XCUITest 断言
                            // NavigationLink 是否真的推入 AlbumScreen（用例 A/B 的判据）
                            .accessibilityIdentifier("album_screen_title")
                        if let author = album.author {
                            Text(author).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let teller = album.teller {
                            Text("播音：\(teller)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(SourceRegistry.displayName(src: album.source))
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                // build 54 · 需求 a（「选中该章节并恢复到历史进度点」）：
                // 打开即看到上次听到哪章、播到几成，一键续听。
                if let plan = resumePlan {
                    Button {
                        playChapter(plan.chapter)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle.fill")
                            Text("继续收听：\(plan.chapter.title) · \(progressText(plan))")
                                .lineLimit(1)
                        }
                        .font(.subheadline)
                    }
                    .accessibilityIdentifier("album_resume_button")
                }
            }

            if let intro = album.intro, !intro.isEmpty {
                Section("简介") {
                    Text(intro).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else if let loadError {
                    Text(loadError).font(.footnote).foregroundStyle(.secondary)
                } else {
                    // UI 增强：目录头「已听 N / 共 M 章」+ 正序/倒序切换（abts 同款交互）
                    HStack(spacing: 8) {
                        Text("目录（\(chapters.count) 章）")
                            .font(.subheadline.weight(.semibold))
                        if (listenedBeforePosition ?? 0) > 0 {
                            Text("已听 \(min(max(0, listenedBeforePosition ?? 0), chapters.count))")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        Button {
                            chaptersReversed.toggle()
                        } label: {
                            Label(chaptersReversed ? "倒序" : "正序",
                                  systemImage: chaptersReversed ? "arrow.down" : "arrow.up")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("album_chapter_order_toggle")
                    }
                    ForEach(displayedChapters) { ch in
                        Button {
                            playChapter(ch)
                        } label: {
                            HStack {
                                // UI 增强：标题自带序号时不重复编号（avoid "0. P1 绪论"）
                                if chapterTitleHasOwnIndex(ch.title) {
                                    Circle().fill(Color.secondary.opacity(isChapterListened(ch) ? 0.25 : 0.5))
                                        .frame(width: 5, height: 5)
                                        .frame(width: 28, alignment: .trailing)
                                } else {
                                    Text("\(ch.index).").font(.caption).foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .trailing)
                                }
                                Text(ch.title).lineLimit(1)
                                if isActivelyPlaying(ch) {
                                    // build 36 · 反馈 6：当前正在播放的章节高亮标识
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                }
                                Spacer()
                                // UI 增强：已听章节 ✓（当前章不显示，避免与高亮冲突）
                                if isChapterListened(ch) && !isCurrentChapter(ch) {
                                    Image(systemName: "checkmark")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("album_chapter_done_\(ch.index)")
                                }
                                if let dur = ch.durationSec {
                                    Text(formatDuration(dur)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .foregroundStyle(isCurrentChapter(ch) ? Color.accentColor : (isChapterListened(ch) ? Color.secondary : Color.primary))
                        .id(ch.id)
                        // build 45.2：章节行稳定锚（用例 H 点第一集；B站分P标题是
                        // UP 自定义名，BEGINSWITH 'P1' 匹配不可靠——CI 第二轮实证）
                        .accessibilityIdentifier("album_chapter_row_\(ch.index)")
                    }
                }
            } header: {
                Text("章节")
            }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.large)
        .task {
            await loadChapters()
        }
        // build 36 · 反馈 6 + build 54：章节列表就绪后定位——
        // 优先「本书正在播放的章」，其次「本书历史章」。
        .onChange(of: chapters) { _, _ in
            applyOpenPositioning(proxy: proxy)
        }
        }
    }

    // MARK: - build 54 · 打开即定位（需求 a / b / c / d / e）

    /// 章节就绪后的定位动作（只做一次）：
    /// 1. 本书正在播放 → 沿用 build 36 行为（滚到播放章），不再重复装载；
    /// 2. 否则取本书历史（合并后的本地真相）→ `OpenResumePlanner.plan`；
    /// 3. 需要时把播放器**静默装载**到历史章与历史位置（`autoPlay:false`，
    ///    不先播第一章再跳——需求 e「无声音闪断」）；
    /// 4. 章节列表滚动到该章（需求 e「打开即到位」）。
    private func applyOpenPositioning(proxy: ScrollViewProxy) {
        guard !chapters.isEmpty, !didScrollToCurrent else { return }
        let pm = container?.playbackManager
        if scrollToPlayingChapter(proxy: proxy) { return }

        let plan = OpenResumePlanner.plan(album: album, chapters: chapters,
                                          snapshots: localHistorySnapshots(),
                                          anchor: queueAnchorForThisAlbum(),
                                          isPlaying: pm?.isPlaying ?? false)
        resumePlan = plan
        guard let plan else { return }   // 需求 d：无历史，行为不变

        if plan.shouldPrepare, let pm {
            // silentWrite: true —— 定位装载**不得写历史**：装载内部会强制落一条
            // 起播记录，若照写，打开一次详情页就把本书 updatedAt 顶成「现在」，
            // 覆盖用户真实续播位置，下次打开会定位到本次装载点而非上次收听点。
            // 只有用户真点播放（playChapter / 继续收听）才落历史。
            pm.prepareQueue(album: album, chapters: chapters,
                            start: .arrayPosition(plan.arrayPosition),
                            startPosMs: plan.startPosMs,
                            silentWrite: true)
        }
        didScrollToCurrent = true
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(plan.chapter.chapterId, anchor: .center)
            }
        }
    }

    /// 本书历史快照（SwiftData 本地）。
    private func localHistorySnapshots() -> [HistorySnapshot] {
        let src = album.source
        let albumId = album.albumId
        let fd = FetchDescriptor<HistoryModel>(
            predicate: #Predicate { $0.src == src && $0.albumId == albumId })
        let rows = (try? modelContext.fetch(fd)) ?? []
        return rows.map { HistorySnapshot($0) }
    }

    private func queueAnchorForThisAlbum() -> QueueAnchor? {
        // build 55 · P2-4：这里必须返回**播放器实际装载态**（哪怕装的是另一本书）——
        // b54 只在本专辑时返回 anchor、否则返回 nil，`shouldPrepare` 把 nil 当成
        // 「播放器空闲」→ 暂停态下打开另一本书就把原队列掀掉。
        guard let pm = container?.playbackManager, let cur = pm.currentAlbum else { return nil }
        return QueueAnchor(src: cur.source, albumId: cur.albumId,
                           arrayPosition: pm.currentChapters.indices.contains(pm.currentChapterIdx)
                               ? pm.currentChapterIdx : nil)
    }

    private func progressText(_ plan: OpenResumePlan) -> String {
        let dur = plan.chapter.durationSec.map { Int64($0) * 1000 } ?? plan.target.durationMs
        guard dur > 0 else { return "已播 \(plan.startPosMs / 1000) 秒" }
        let pct = Int(Double(plan.startPosMs) / Double(dur) * 100)
        return "已播 \(min(max(pct, 0), 100))%"
    }

    /// build 36 · 反馈 6：本专辑正在播放时，取播放中章节定位（只定位一次）。
    /// 匹配口径：专辑（source + albumId）一致 且 章节列表含播放中章节（chapterId 匹配）。
    private func scrollToPlayingChapter(proxy: ScrollViewProxy) -> Bool {
        guard !didScrollToCurrent,
              let pm = container?.playbackManager,
              pm.currentAlbum?.albumId == album.albumId,
              pm.currentAlbum?.source == album.source,
              pm.currentChapterIdx >= 0, pm.currentChapterIdx < pm.currentChapters.count else { return false }
        let playing = pm.currentChapters[pm.currentChapterIdx]
        guard chapters.contains(where: { $0.chapterId == playing.chapterId }) else { return false }
        didScrollToCurrent = true
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(playing.chapterId, anchor: .center)
            }
        }
        return true
    }

    /// 该章节是否为当前章（高亮判定）：播放器装载本书且停在该章 → 是；
    /// 否则回落到「打开书的历史定位章」。
    private func isCurrentChapter(_ ch: Chapter) -> Bool {
        if let pm = container?.playbackManager,
           pm.currentAlbum?.albumId == album.albumId,
           pm.currentAlbum?.source == album.source,
           pm.currentChapterIdx >= 0, pm.currentChapterIdx < pm.currentChapters.count,
           pm.currentChapters[pm.currentChapterIdx].chapterId == ch.chapterId {
            return true
        }
        if let plan = resumePlan { return plan.chapter.chapterId == ch.chapterId }
        return false
    }

    /// UI 增强：该章是否已听（数组位置上早于当前进度章）。
    /// 当前章不算已听（避免与高亮/喇叭冲突）；无历史时全部未听。
    private func isChapterListened(_ ch: Chapter) -> Bool {
        guard let position = listenedBeforePosition else { return false }
        guard let idx = chapters.firstIndex(where: { $0.chapterId == ch.chapterId }) else { return false }
        return idx < position
    }

    /// UI 增强：章节标题是否自带序号——纯函数见 `ChapterTitleFormatting.hasOwnIndex`，
    /// 与 abts `_ownIndex` 正则等价，单测见 AlbumChapterUITests。
    private func chapterTitleHasOwnIndex(_ title: String) -> Bool {
        ChapterTitleFormatting.hasOwnIndex(title)
    }

    /// 只有确实在出声播放时显示喇叭图标（历史高亮不冒播放态）。
    private func isActivelyPlaying(_ ch: Chapter) -> Bool {
        guard let pm = container?.playbackManager, pm.isPlaying,
              pm.currentAlbum?.albumId == album.albumId,
              pm.currentAlbum?.source == album.source,
              pm.currentChapterIdx >= 0, pm.currentChapterIdx < pm.currentChapters.count else { return false }
        return pm.currentChapters[pm.currentChapterIdx].chapterId == ch.chapterId
    }

    /// 多源章节加载（P0-3 / P1-10：复用容器内 SourceRouter，不再自建 APIClient）
    private func loadChapters() async {
        guard let router = container?.sourceRouter else { return }
        do {
            chapters = try await router.chapters(
                src: album.source,
                albumId: album.albumId,
                detailPath: album.detailPath)
        } catch let error as PaidChapterException {
            loadError = "该专辑为付费内容，已拦截"
        } catch {
            loadError = "章节加载失败：\(error.localizedDescription)"
            print("Album load error (\(album.source)): \(error)")
        }
        isLoading = false
    }

    /// build 54：点章播放。**点的正是历史定位章**时从历史位置续播
    /// （需求 a/b：不用手动翻找、不用自己拖进度）；其余章从 0 起播（原行为不变）。
    private func playChapter(_ ch: Chapter) {
        let resumeMs: Int64 = {
            guard let plan = resumePlan, plan.chapter.index == ch.index else { return 0 }
            return plan.startPosMs
        }()
        container?.playbackManager.playQueue(
            album: album,
            chapters: chapters,
            startIdx: ch.index,
            startPosMs: resumeMs)
    }

    private func formatDuration(_ sec: Int) -> String {
        String(format: "%d:%02d", sec / 60, sec % 60)
    }
}
