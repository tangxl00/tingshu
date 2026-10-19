import SwiftUI
import SwiftData

/// 书架页：最近收听 + 我的收藏。
/// 修复（真机 v1.3.3 症状2）：原先 HistoryRow/FavoriteRow 等子项是纯展示视图，
/// 没有任何 NavigationLink / onTapGesture，点击书籍无任何反应。
/// 现在所有条目点击均经 NavigationLink 跳转 AlbumScreen 详情页，
/// 并用 DiagLog 埋点（os.Logger，release 构建也可在 Console.app / 爱思助手看到）。
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
                                    ForEach(histories.prefix(20), id: \.self) { h in
                                        NavigationLink {
                                            AlbumScreen(album: h.toAlbum())
                                        } label: {
                                            HistoryRow(history: h)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                                    ForEach(histories.prefix(20), id: \.self) { h in
                                        NavigationLink {
                                            AlbumScreen(album: h.toAlbum())
                                        } label: {
                                            HistoryGridItem(history: h)
                                        }
                                        .buttonStyle(.plain)
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
                                        NavigationLink {
                                            AlbumScreen(album: f.toAlbum())
                                        } label: {
                                            FavoriteRow(favorite: f)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                                    ForEach(favorites) { f in
                                        NavigationLink {
                                            AlbumScreen(album: f.toAlbum())
                                        } label: {
                                            FavoriteGridItem(favorite: f)
                                        }
                                        .buttonStyle(.plain)
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

// MARK: - SwiftData 模型 -> Album 还原（供详情页路由）

extension HistoryModel {
    func toAlbum() -> Album {
        Album(
            albumId: albumId,
            title: albumTitle,
            author: nil,
            teller: nil,
            coverUrl: coverUrl,
            intro: nil,
            category: nil,
            categoryId: nil,
            type: nil,
            typeId: nil,
            status: nil,
            chapterCount: nil,
            updatedAt: updatedAt,
            playCount: nil,
            available: nil,
            source: src,
            detailPath: detailPath)
    }
}

extension FavoriteModel {
    func toAlbum() -> Album {
        Album(
            albumId: albumId,
            title: title,
            author: author,
            teller: teller,
            coverUrl: coverUrl,
            intro: nil,
            category: nil,
            categoryId: nil,
            type: nil,
            typeId: nil,
            status: status,
            chapterCount: chapterCount,
            updatedAt: createdAt,
            playCount: nil,
            available: nil,
            source: src,
            detailPath: detailPath)
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
        .contentShape(Rectangle())
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
        .contentShape(Rectangle())
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
        .contentShape(Rectangle())
    }
}

struct FavoriteGridItem: View {
    let favorite: FavoriteModel
    var body: some View {
        VStack(spacing: 4) {
            CoverImage(url: favorite.coverUrl, size: 100)
            Text(favorite.title).lineLimit(1).font(.caption)
        }
        .contentShape(Rectangle())
    }
}
