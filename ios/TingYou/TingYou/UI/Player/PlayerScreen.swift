import SwiftUI

struct PlayerScreen: View {
    @State private var viewModel = PlayerViewModel()
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                CoverImage(url: viewModel.coverUrl, size: 280)
                    .padding(.top)

                VStack(spacing: 4) {
                    Text(viewModel.albumTitle).font(.headline).lineLimit(1)
                    Text(viewModel.chapterTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }

                DotProgress(
                    value: viewModel.durationMs > 0 ? Double(viewModel.currentPositionMs) / Double(viewModel.durationMs) : 0,
                    onSeek: { pct in
                        viewModel.seekTo(pct: pct)
                    }
                )
                .frame(height: 40)
                .padding(.horizontal)

                HStack {
                    Text(formatMs(viewModel.currentPositionMs)).font(.caption).monospacedDigit()
                    Spacer()
                    Text(formatMs(viewModel.durationMs)).font(.caption).monospacedDigit()
                }
                .padding(.horizontal)

                HStack(spacing: 40) {
                    Button { viewModel.previous() } label: {
                        Image(systemName: "backward.end.fill").font(.title2)
                    }
                    Button { viewModel.togglePlay() } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                    Button { viewModel.next() } label: {
                        Image(systemName: "forward.end.fill").font(.title2)
                    }
                }
                .foregroundStyle(.primary)

                HStack(spacing: 32) {
                    Button { viewModel.seekRelative(-15000) } label: {
                        Image(systemName: "gobackward.15").font(.title3)
                    }
                    Button { viewModel.showSpeedSheet = true } label: {
                        Text("\(String(format: "%.1f", viewModel.speed))x").font(.caption).monospacedDigit()
                    }
                    Button { viewModel.seekRelative(15000) } label: {
                        Image(systemName: "goforward.15").font(.title3)
                    }
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 32) {
                    Button { viewModel.showChapters = true } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "list.bullet").font(.title3)
                            Text("章节").font(.caption2)
                        }
                    }
                    Button { viewModel.showSleepTimer = true } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "moon.fill").font(.title3)
                            Text("定时").font(.caption2)
                        }
                    }
                    Button { viewModel.toggleFavorite() } label: {
                        VStack(spacing: 2) {
                            Image(systemName: viewModel.isFavorite ? "heart.fill" : "heart").font(.title3)
                            Text("收藏").font(.caption2)
                        }
                    }
                    Button { viewModel.showSettings = true } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "gearshape").font(.title3)
                            Text("设置").font(.caption2)
                        }
                    }
                }
                .foregroundStyle(.secondary)

                Spacer(minLength: 20)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $viewModel.showSpeedSheet) {
                SpeedSheet(speed: $viewModel.speed) { s in viewModel.setSpeed(s) }
            }
            .sheet(isPresented: $viewModel.showChapters) {
                ChapterListSheet(chapters: viewModel.chapters, currentIdx: viewModel.currentChapterIdx) { idx in
                    viewModel.playChapter(index: idx)
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
}
