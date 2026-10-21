import SwiftUI
import UIKit

struct PlayerScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    /// build 23：弹窗呈现机制重构——四个 `.sheet(isPresented:)` 挂在同一视图链上是
    /// SwiftUI 已知限制（只有最后挂载的可靠生效），真机表现为倍速/章节按钮点不出弹窗。
    /// 官方推荐形态：单枚举驱动 `.sheet(item:)`，同一时刻最多呈现一个弹窗，行为确定。
    enum PlayerSheet: Identifiable, Equatable {
        case speed, chapters, sleepTimer, settings
        var id: Self { self }
    }

    @State private var activeSheet: PlayerSheet?
    @State private var isFavorite = false

    private var pm: PlaybackManager? { container?.playbackManager }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CoverImage(url: pm?.coverUrl, size: 280, source: pm?.currentAlbum?.source)
                        .padding(.top)

                    VStack(spacing: 4) {
                        Text(pm?.currentAlbumTitle ?? "").font(.headline).lineLimit(1)
                        Text(pm?.currentChapterTitle ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }

                    DotProgress(
                        value: (pm?.durationMs ?? 0) > 0 ? Double(pm?.currentPositionMs ?? 0) / Double(pm!.durationMs) : 0,
                        onSeek: { pct in
                            let pos = Int64(Double(pm?.durationMs ?? 0) * pct)
                            pm?.seek(to: pos)
                        }
                    )
                    .frame(height: 40)
                    .padding(.horizontal)

                    HStack {
                        Text(formatMs(pm?.currentPositionMs ?? 0)).font(.caption).monospacedDigit()
                        Spacer()
                        Text(formatMs(pm?.durationMs ?? 0)).font(.caption).monospacedDigit()
                    }
                    .padding(.horizontal)

                    HStack(spacing: 40) {
                        Button { pm?.previousChapter() } label: {
                            Image(systemName: "backward.end.fill").font(.title2)
                        }
                        Button { pm?.togglePlayPause() } label: {
                            Image(systemName: (pm?.isPlaying ?? false) ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 64))
                        }
                        Button { pm?.nextChapter() } label: {
                            Image(systemName: "forward.end.fill").font(.title2)
                        }
                    }
                    .foregroundStyle(.primary)

                    HStack(spacing: 32) {
                        Button { pm?.seekRelative(-15000) } label: {
                            Image(systemName: "gobackward.15").font(.title3)
                        }
                        Button { activeSheet = .speed } label: {
                            Text("\(String(format: "%.1f", pm?.speed ?? 1.0))x")
                                .font(.caption).monospacedDigit()
                        }
                        // build 25（顺手项）：补按压视觉反馈（章节/定时/收藏均有，速度按钮漏挂）
                        .buttonStyle(.pressable)
                        Button { pm?.seekRelative(15000) } label: {
                            Image(systemName: "goforward.15").font(.title3)
                        }
                    }
                    .foregroundStyle(.secondary)

                    HStack(spacing: 32) {
                        Button { activeSheet = .chapters } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "list.bullet").font(.title3)
                                Text("章节").font(.caption2)
                            }
                        }
                        .buttonStyle(.pressable)
                        Button { activeSheet = .sleepTimer } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "moon.fill").font(.title3)
                                Text("定时").font(.caption2)
                            }
                        }
                        .buttonStyle(.pressable)
                        // Bug 2：收藏真实落库（原为本地 @State 切换，重启即失）
                        Button { toggleFavorite() } label: {
                            VStack(spacing: 2) {
                                Image(systemName: isFavorite ? "heart.fill" : "heart").font(.title3)
                                    .foregroundStyle(isFavorite ? Color.pink : Color.secondary)
                                Text("收藏").font(.caption2)
                            }
                        }
                        .buttonStyle(.pressable)
                        Button { activeSheet = .settings } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "gearshape").font(.title3)
                                Text("设置").font(.caption2)
                            }
                        }
                        .buttonStyle(.pressable)
                        // build 21 · 反馈 1（Bug A）：分享改 SwiftUI 原生 ShareLink。
                        // 旧实现从 rootViewController present UIActivityViewController，
                        // 在 SwiftUI presentation 层级下（PlayerScreen 自身处于 sheet 内）会被吞掉。
                        ShareLink(item: shareText) {
                            VStack(spacing: 2) {
                                Image(systemName: "square.and.arrow.up").font(.title3)
                                Text("分享").font(.caption2)
                            }
                        }
                        .buttonStyle(.pressable)
                    }
                    .foregroundStyle(.secondary)

                    Spacer(minLength: 20)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            // build 23：四个 `.sheet(isPresented:)` 合并为单枚举驱动的 `.sheet(item:)`——
            // 同一视图链上多个 sheet 修饰符只有最后挂载的可靠生效（SwiftUI 已知限制），
            // build 22 真机表现为倍速/章节弹窗点不出来；`sheet(item:)` 是官方推荐形态。
            // ShareLink 与 .task 保持不动（非弹窗呈现机制）。
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .speed:
                    SpeedSheet(speed: Binding(
                        get: { pm?.speed ?? 1.0 },
                        set: { pm?.speed = $0 }
                    )) { s in pm?.speed = s }
                case .chapters:
                    ChapterListSheet(
                        chapters: pm?.currentChapters ?? [],
                        // 用真实章序号定位当前项（原按标题匹配，同名章节会错位）
                        currentIdx: pm?.currentChapterIdx ?? 0
                    ) { idx in
                        pm?.playChapter(at: idx)
                    }
                case .sleepTimer:
                    // build 21 · 反馈 1（Bug A）：定时弹窗接线——逻辑复用 build 20 已修好的
                    // applySleepTimer 三模式体系。
                    SleepTimerSheet(
                        config: Binding(
                            get: { pm?.sleepConfig ?? SleepTimerConfig() },
                            set: { c in pm?.applySleepTimer(config: c) }
                        )
                    ) { c in
                        pm?.applySleepTimer(config: c)
                    }
                case .settings:
                    // build 21 · 反馈 1（Bug A）：设置面板接线——播放模式
                    // （顺序/单曲循环/列表循环），逻辑在 PlaybackManager.chapterFinishedAction。
                    // build 25（对齐安卓 v1.3.0 item 8）：新增片头/片尾跳过接线——
                    // 读当前书秒数、拖动结束落值（按书持久化，换书自动刷新）。
                    PlayerSettingsSheet(
                        playMode: Binding(
                            get: { pm?.playMode ?? .sequence },
                            set: { m in pm?.setPlayMode(m) }
                        ),
                        introSec: pm?.introSkipSeconds ?? 0,
                        outroSec: pm?.outroSkipSeconds ?? 0,
                        onSelect: { m in pm?.setPlayMode(m) },
                        onIntroChange: { sec in pm?.setIntroSkip(sec) },
                        onOutroChange: { sec in pm?.setOutroSkip(sec) }
                    )
                }
            }
        }
        .task(id: favoriteKey) {
            // Bug 2：收藏态从数据库初始化（原为固定 false）
            await refreshFavorite()
        }
    }

    /// 收藏定位键：当前专辑变化时重新查库
    private var favoriteKey: String {
        "\(pm?.currentAlbum?.source ?? "")|\(pm?.currentAlbum?.albumId ?? 0)"
    }

    private func refreshFavorite() async {
        guard let album = pm?.currentAlbum,
              let repo = container?.albumRepository else { return }
        isFavorite = await repo.isFavorite(src: album.source, albumId: album.albumId)
    }

    private func toggleFavorite() {
        guard let album = pm?.currentAlbum,
              let repo = container?.albumRepository else { return }
        Task {
            if isFavorite {
                await repo.removeFavorite(src: album.source, albumId: album.albumId)
            } else {
                await repo.addFavorite(album: album)
            }
            // 以库为准回读，避免并发态错位
            isFavorite = await repo.isFavorite(src: album.source, albumId: album.albumId)
        }
    }

    func formatMs(_ ms: Int64) -> String {
        let sec = ms / 1000
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// build 21 · 反馈 1：ShareLink 的分享文案。
    private var shareText: String {
        let title = pm?.currentAlbumTitle ?? ""
        return title.isEmpty ? "推荐一个听书 App" : "我在听《\(title)》，推荐给你"
    }
}
