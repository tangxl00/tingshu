import SwiftUI

struct DiscoverScreen: View {
    @State private var viewModel = DiscoverViewModel()
    @State private var selectedSection = "recommend"
    let sections = [("recommend","推荐"),("new","最新"),("hot","热门"),("serial","连载"),("story","评书")]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(sections, id: \.0) { key, name in
                            Button(name) {
                                selectedSection = key
                                Task { await viewModel.loadRank(section: key) }
                            }
                            .fontWeight(selectedSection == key ? .bold : .regular)
                            .foregroundStyle(selectedSection == key ? .primary : .secondary)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)

                List {
                    ForEach(viewModel.albums) { album in
                        AlbumRow(album: album)
                    }
                    if viewModel.hasMore {
                        ProgressView()
                            .onAppear {
                                Task { await viewModel.loadMore() }
                            }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("发现")
            .task {
                await viewModel.loadRank(section: selectedSection)
            }
        }
    }
}

struct AlbumRow: View {
    let album: Album
    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: album.coverUrl, size: 70)
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title).lineLimit(2).font(.subheadline)
                if let author = album.author {
                    Text(author).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
                if let count = album.chapterCount {
                    Text("\(count)集").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
