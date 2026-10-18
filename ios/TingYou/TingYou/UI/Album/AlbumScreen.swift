import SwiftUI

struct AlbumScreen: View {
    let album: Album
    @State private var chapters: [Chapter] = []
    @State private var isLoading = true
    @Environment(\.appContainer) private var container

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    CoverImage(url: album.coverUrl, size: 120)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title).font(.headline).lineLimit(2)
                        if let author = album.author {
                            Text(author).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let intro = album.intro {
                            Text(intro).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("章节") {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(chapters) { ch in
                        Button {
                            // play chapter
                        } label: {
                            HStack {
                                Text("\(ch.index).").font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                                Text(ch.title).lineLimit(1)
                                Spacer()
                                if let dur = ch.durationSec {
                                    Text(formatSec(dur)).font(.caption).foregroundStyle(.secondary)
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
            await loadChapters()
        }
    }

    private func loadChapters() async {
        do {
            let client = APIClient()
            let repo = AlbumRepository(apiClient: client, modelContext: ModelContext(.init(schema: Schema([]))))
            chapters = try await repo.chapters(albumId: album.albumId)
        } catch {
            print("Album load error: \(error)")
        }
        isLoading = false
    }

    func formatSec(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }
}
