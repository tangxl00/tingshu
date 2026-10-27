import SwiftUI

/// 专辑详情页：章节列表按专辑来源走 SourceRouter 真实路由（P0-3）——
/// tingyou 走 JSON API；
/// 点击章节经 PlaybackManager 播放（占位 URI 由 AVAssetResourceLoaderDelegate 惰性解析直链）。
/// build 45 · 反馈 3：悦听（ytysxs）摘除——AntibotException 拦截文案删除
///（存量 ytysxs 书 chapters 走 default 分支报「源已下架」）。
struct AlbumScreen: View {
    let album: Album
    @State private var chapters: [Chapter] = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// build 36 · 反馈 6：章节列表加载完成后是否已自动定位过（只定位一次，切章不抢滚动）
    @State private var didScrollToCurrent = false
    @Environment(\.appContainer) private var container

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
                                if isPlayingChapter(ch) {
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
                        .foregroundStyle(isPlayingChapter(ch) ? Color.accentColor : .primary)
                        .id(ch.id)
                    }
                }
            }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.large)
        .task {
            await loadChapters()
        }
        // build 36 · 反馈 6：章节列表就绪后自动滚动定位到当前正在播放的章节
        .onChange(of: chapters) { _, _ in
            scrollToCurrentChapter(proxy: proxy)
        }
        }
    }

    /// build 36 · 反馈 6：本专辑正在播放时，取播放中章节定位（只定位一次）。
    /// 匹配口径：专辑（source + albumId）一致 且 章节列表含播放中章节（chapterId 匹配）。
    private func scrollToCurrentChapter(proxy: ScrollViewProxy) {
        guard !didScrollToCurrent,
              let pm = container?.playbackManager,
              pm.currentAlbum?.albumId == album.albumId,
              pm.currentAlbum?.source == album.source,
              pm.currentChapterIdx >= 0, pm.currentChapterIdx < pm.currentChapters.count else { return }
        let playing = pm.currentChapters[pm.currentChapterIdx]
        guard chapters.contains(where: { $0.chapterId == playing.chapterId }) else { return }
        didScrollToCurrent = true
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(playing.chapterId, anchor: .center)
            }
        }
    }

    /// build 36 · 反馈 6：该章节是否为当前正在播放的章节（章节行高亮判定）。
    private func isPlayingChapter(_ ch: Chapter) -> Bool {
        guard let pm = container?.playbackManager,
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

    private func playChapter(_ ch: Chapter) {
        container?.playbackManager.playQueue(
            album: album,
            chapters: chapters,
            startIdx: ch.index)
    }

    private func formatDuration(_ sec: Int) -> String {
        String(format: "%d:%02d", sec / 60, sec % 60)
    }
}
