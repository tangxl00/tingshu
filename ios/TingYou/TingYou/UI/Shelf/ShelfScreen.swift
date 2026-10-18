import SwiftUI
import SwiftData

struct ShelfScreen: View {
    @Query(sort: \FavoriteModel.createdAt, order: .reverse) private var favorites: [FavoriteModel]
    @Query(sort: \HistoryModel.updatedAt, order: .reverse) private var histories: [HistoryModel]
    @State private var layout: Int = 0
    @Environment(\.appContainer) private var container

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("布局", selection: $layout) {
                    Text("列表").tag(0)
                    Text("九宫格").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    if !histories.isEmpty {
                        Section(header: Text("最近收听").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)) {
                            if layout == 0 {
                                LazyVStack(spacing: 12) {
                                    ForEach(histories.prefix(20), id: \Self.updatedAt) { h in
                                        HistoryRow(history: h)
                                    }
                                }
                                .padding(.horizontal)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                                    ForEach(histories.prefix(20), id: \Self.updatedAt) { h in
                                        HistoryGridItem(history: h)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    if !favorites.isEmpty {
                        Section(header: Text("我的收藏").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)) {
                            if layout == 0 {
                                LazyVStack(spacing: 12) {
                                    ForEach(favorites) { f in
                                        FavoriteRow(favorite: f)
                                    }
                                }
                                .padding(.horizontal)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                                    ForEach(favorites) { f in
                                        FavoriteGridItem(favorite: f)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    if histories.isEmpty && favorites.isEmpty {
                        ContentUnavailableView("书架为空", systemImage: "books.vertical", description: Text("在发现页浏览并收藏书籍"))
                    }
                }
            }
            .navigationTitle("书架")
        }
    }
}

struct HistoryRow: View {
    let history: HistoryModel
    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: history.coverUrl, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(history.albumTitle).lineLimit(1).font(.subheadline)
                Text("\(history.chapterTitle)").lineLimit(1).font(.caption).foregroundStyle(.secondary)
                Text(progressText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    var progressText: String {
        let pct = history.durationMs > 0 ? Int(Double(history.positionMs) / Double(history.durationMs) * 100) : 0
        return "已播 \(pct)%"
    }
}

struct HistoryGridItem: View {
    let history: HistoryModel
    var body: some View {
        VStack(spacing: 4) {
            CoverImage(url: history.coverUrl, size: 100)
            Text(history.albumTitle).lineLimit(1).font(.caption)
            Text("\(history.chapterTitle)").lineLimit(1).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct FavoriteRow: View {
    let favorite: FavoriteModel
    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: favorite.coverUrl, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(favorite.title).lineLimit(1).font(.subheadline)
                if let author = favorite.author {
                    Text(author).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct FavoriteGridItem: View {
    let favorite: FavoriteModel
    var body: some View {
        VStack(spacing: 4) {
            CoverImage(url: favorite.coverUrl, size: 100)
            Text(favorite.title).lineLimit(1).font(.caption)
        }
    }
}
