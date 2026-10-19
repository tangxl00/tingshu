import SwiftUI
import UIKit

struct PlayerScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var showSpeedSheet = false
    @State private var showChapters = false
    @State private var showSleepTimer = false
    @State private var showSettings = false
    @State private var isFavorite = false

    private var pm: PlaybackManager? { container?.playbackManager }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CoverImage(url: pm?.coverUrl, size: 280)
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
                        Button { showSpeedSheet = true } label: {
                            Text("\(String(format: "%.1f", pm?.speed ?? 1.0))x")
                                .font(.caption).monospacedDigit()
                        }
                        Button { pm?.seekRelative(15000) } label: {
                            Image(systemName: "goforward.15").font(.title3)
                        }
                    }
                    .foregroundStyle(.secondary)

                    HStack(spacing: 32) {
                        Button { showChapters = true } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "list.bullet").font(.title3)
                                Text("章节").font(.caption2)
                            }
                        }
                        Button { showSleepTimer = true } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "moon.fill").font(.title3)
                                Text("定时").font(.caption2)
                            }
                        }
                        Button { isFavorite.toggle() } label: {
                            VStack(spacing: 2) {
                                Image(systemName: isFavorite ? "heart.fill" : "heart").font(.title3)
                                Text("收藏").font(.caption2)
                            }
                        }
                        Button { showSettings = true } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "gearshape").font(.title3)
                                Text("设置").font(.caption2)
                            }
                        }
                        Button { shareAlbum() } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "square.and.arrow.up").font(.title3)
                                Text("分享").font(.caption2)
                            }
                        }
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
            .sheet(isPresented: $showSpeedSheet) {
                SpeedSheet(speed: Binding(
                    get: { pm?.speed ?? 1.0 },
                    set: { pm?.speed = $0 }
                )) { _ in }
            }
            .sheet(isPresented: $showChapters) {
                ChapterListSheet(
                    chapters: pm?.currentChapters ?? [],
                    currentIdx: pm?.currentChapters.firstIndex(where: {
                        $0.title == (pm?.currentChapterTitle ?? "")
                    }) ?? 0
                ) { idx in
                    pm?.playChapter(at: idx)
                }
            }
        }
    }

    func formatMs(_ ms: Int64) -> String {
        let sec = ms / 1000
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func shareAlbum() {
        let text = "我在听《\(pm?.currentAlbumTitle ?? "")》，推荐给你"
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(av, animated: true)
        }
    }
}
