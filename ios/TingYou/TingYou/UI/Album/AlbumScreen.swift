import SwiftUI
import SwiftData

/// 专辑详情页：章节列表按专辑来源走 SourceRouter 真实路由（P0-3）——
/// tingyou 走 JSON API；
/// 点击章节经 PlaybackManager 播放（占位 URI 由 AVAssetResourceLoaderDelegate 惰性解析直链）。
/// build 45 · 反馈 3：悦听（ytysxs）摘除——AntibotException 拦截文案删除
///（存量 ytysxs 书 chapters 走 default 分支报「源已下架」）。
///
/// build 54 · 需求 a/b/c/d/e（历史进度定位）：打开本书即定位到上次收听——
/// 数据源是**合并后的本地历史**（`HistoryModel`；云端较新者已由 SyncEngine 按
/// `updated_at` LWW 落库），本页只读本地、不拉云；定位 = 章节列表滚动到该章
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
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var modelContext

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

            Section("章节") {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else if let loadError {
                    Text(loadError).font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(chapters) { ch in
                        Button {
                            playChapter(ch)
                        } label: {
                            HStack {
                                Text("\(ch.index).").font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                                Text(ch.title).lineLimit(1)
                                if isActivelyPlaying(ch) {
                                    // build 36 · 反馈 6：当前正在播放的章节高亮标识
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                }
                                Spacer()
                                if let dur = ch.durationSec {
                                    Text(formatDuration(dur)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .foregroundStyle(isCurrentChapter(ch) ? Color.accentColor : .primary)
                        .id(ch.id)
                        // build 45.2：章节行稳定锚（用例 H 点第一集；B站分P标题是
                        // UP 自定义名，BEGINSWITH 'P1' 匹配不可靠——CI 第二轮实证）
                        .accessibilityIdentifier("album_chapter_row_\(ch.index)")
                    }
                }
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
            // SyncEngine 的 LWW 判定翻成本地较新，云端真正较新的进度反被压住
            // （跨端续播回退）。只有用户真点播放（playChapter / 继续收听）才落历史。
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

    /// 本书历史快照（SwiftData 本地，已含云端合并结果；不直连云）。
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
