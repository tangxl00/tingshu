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
        // build 54 · 需求 c（1 基源早一章缺陷修复）：`HistoryResumePlanner.locate`
        // 给出的是**数组位置（0 基）**，旧实现传 `startIdx:` 会被当成「章 index 值」
        // 再匹配一次——1 基源上位置 k-1 命中章号 k-1，启动恢复稳定早一章。
        // 现显式走 `start:` 的 `.arrayPosition`，不做二次猜测。
        switch outcome {
        // build 54 · 需求 c：启动恢复同样 silentWrite——恢复是「读取历史」而非「产生进度」，
        // 若照写会把本书 updatedAt 顶成「现在」，令 SyncEngine LWW 把云端真正较新的
        // 进度判成「旧」而拒绝合并（跨端续播回退）。用户真点播放才落历史。
        case .fullQueue(let chapters, let startIdx):
            container.playbackManager.prepareQueue(
                album: album, chapters: chapters,
                start: .arrayPosition(startIdx), startPosMs: latest.positionMs,
                silentWrite: true
            )
        case .singleChapter(let chapter):
            // 降级单章：数组只有一章，位置恒为 0
            container.playbackManager.prepareQueue(
                album: album, chapters: [chapter],
                start: .arrayPosition(0), startPosMs: latest.positionMs,
                silentWrite: true
            )
        }
    }
}
