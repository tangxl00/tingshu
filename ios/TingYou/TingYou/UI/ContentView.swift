import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab = 1
    @State private var showPlayer = false
    @Environment(\.appContainer) private var container
    /// build 21 · 反馈 3（增强 1）：启动恢复只跑一次
    @State private var didRestoreOnLaunch = false

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                ShelfScreen(
                    onOpenPlayer: { showPlayer = true }
                )
                .tabItem {
                    Image(systemName: "books.vertical")
                    Text("书架")
                }
                .tag(0)

                DiscoverScreen(
                    onOpenAlbum: { _ in },
                    onOpenPlayer: { showPlayer = true }
                )
                .tabItem {
                    Image(systemName: "safari")
                    Text("发现")
                }
                .tag(1)

                MineScreen()
                .tabItem {
                    Image(systemName: "person.crop.circle")
                    Text("我的")
                }
                .tag(2)
            }

            // Mini Player Bar overlay above Tab Bar
            VStack {
                Spacer()
                MiniPlayerBar(onTap: {
                    showPlayer = true
                })
                .padding(.bottom, 49) // Tab bar height
            }
            .ignoresSafeArea(.keyboard)
        }
        .sheet(isPresented: $showPlayer) {
            PlayerScreen()
        }
        // build 21 · 反馈 3（增强 1）：打开 App 自动记忆上次播放——载入最新一条历史，
        // 重建完整章节队列并定位到上次进度，迷你条显示但不自动出声（用户点播放才播）。
        .task {
            guard !didRestoreOnLaunch else { return }
            didRestoreOnLaunch = true
            await restoreLastSession()
        }
    }

    /// 启动恢复：读最新一条 HistoryModel → HistoryResumePlanner 重建队列 →
    /// prepareQueue（不调 play()）。拉取失败降级单章（planner 内建）。
    /// 无历史 / 无容器（预览态）保持现状不动。
    private func restoreLastSession() async {
        guard let container else { return }
        let ctx = container.modelContainer.mainContext
        let descriptor = FetchDescriptor<HistoryModel>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        guard let latest = try? ctx.fetch(descriptor).first else { return }

        let album = Album(
            albumId: latest.albumId, title: latest.albumTitle, author: nil, teller: nil,
            coverUrl: latest.coverUrl, intro: nil, category: nil, categoryId: nil,
            type: nil, typeId: nil, status: nil, chapterCount: nil,
            updatedAt: nil, playCount: nil, available: true,
            source: latest.src, detailPath: latest.detailPath
        )
        let router = container.sourceRouter
        let planner = HistoryResumePlanner(fetchChapters: { src, albumId, detailPath in
            // sourceRouter 为非可选值（CI 编译错误修正：guard let 不成立），直接使用
            return try await router.chapters(src: src, albumId: albumId, detailPath: detailPath)
        })
        let outcome = await planner.plan(
            src: latest.src, albumId: latest.albumId, detailPath: latest.detailPath,
            chapterIdx: latest.chapterIdx, chapterTitle: latest.chapterTitle
        )
        // 恢复不出声：prepareQueue 只装载（autoPlay:false），不调用 play()。
        // 迷你播放条由 currentAlbum 驱动自然显示，用户点播放续听。
        switch outcome {
        case .fullQueue(let chapters, let startIdx):
            container.playbackManager.prepareQueue(
                album: album, chapters: chapters, startIdx: startIdx, startPosMs: latest.positionMs
            )
        case .singleChapter(let chapter):
            container.playbackManager.prepareQueue(
                album: album, chapters: [chapter], startIdx: 0, startPosMs: latest.positionMs
            )
        }
    }
}
