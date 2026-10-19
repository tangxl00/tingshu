import SwiftUI

/// 专辑详情页：章节列表按专辑来源走 SourceRouter 真实路由（P0-3）——
/// tingyou 走 JSON API；ting15/ting08/悦听/书音FM 各自适配器解析；
/// 点击章节经 PlaybackManager 播放（占位 URI 由 AVAssetResourceLoaderDelegate 惰性解析直链）。
struct AlbumScreen: View {
    let album: Album
    @State private var chapters: [Chapter] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @Environment(\.appContainer) private var container

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    CoverImage(url: album.coverUrl, size: 90)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title).font(.headline).lineLimit(2)
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
                                Spacer()
                                if let dur = ch.durationSec {
                                    Text(formatDuration(dur)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.large)
        .task {
            DiagLog.mark(self, "进入专辑详情: src=\(album.source) albumId=\(album.albumId) title=\(album.title)")
            await loadChapters()
        }
    }

    /// 多源章节加载（P0-3 / P1-10：复用容器内 SourceRouter，不再自建 APIClient）
    private func loadChapters() async {
        guard let router = container?.sourceRouter else {
            DiagLog.mark(self, "AppContainer 缺失，无法加载章节")
            isLoading = false
            return
        }
        do {
            chapters = try await router.chapters(
                src: album.source,
                albumId: album.albumId,
                detailPath: album.detailPath)
            DiagLog.mark(self, "章节加载成功: \(chapters.count) 集 (src=\(album.source))")
        } catch let error as AntibotException {
            DiagLog.mark(self, "章节加载被反爬拦截 (src=\(album.source)): \(error)")
            loadError = "悦听反爬拦截：请在搜索页完成人工验证后重试"
        } catch let error as PaidChapterException {
            DiagLog.mark(self, "章节为付费内容被拦截 (src=\(album.source)): \(error)")
            loadError = "该专辑为付费内容，已拦截"
        } catch {
            DiagLog.mark(self, "章节加载失败 (src=\(album.source)): \(error.localizedDescription)")
            loadError = "章节加载失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func playChapter(_ ch: Chapter) {
        DiagLog.mark(self, "点击播放: 第\(ch.index)章「\(ch.title)」")
        container?.playbackManager.playQueue(
            album: album,
            chapters: chapters,
            startIdx: ch.index)
    }

    private func formatDuration(_ sec: Int) -> String {
        String(format: "%d:%02d", sec / 60, sec % 60)
    }
}
