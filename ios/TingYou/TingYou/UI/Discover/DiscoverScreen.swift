import SwiftUI

struct DiscoverScreen: View {
    @Environment(\.appContainer) private var appContainer
    @State private var viewModel = DiscoverViewModel()
    @State private var selectedSection = "recommend"
    @State private var keyword = ""
    @State private var searchMode = false
    @State private var searchResults: [Album] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchHasMore = false
    @State private var searchPage = 1
    @State private var showAntibotSheet = false
    @State private var pendingKeyword = ""

    let onOpenAlbum: (Int64) -> Void
    let onOpenPlayer: () -> Void

    let sections = [("recommend","推荐"),("new","最新"),("hot","热门"),("serial","连载"),("story","评书")]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索书名 / 作者 / 主播", text: $keyword)
                        .submitLabel(.search)
                        .onSubmit {
                            performSearch(initial: true)
                        }
                    if !keyword.isEmpty {
                        Button(action: {
                            keyword = ""
                            searchMode = false
                            searchResults = []
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.vertical, 8)

                if searchMode && !keyword.isEmpty {
                    searchResultsContent
                } else {
                    libraryContent
                }
            }
            .navigationTitle(searchMode ? "搜索" : "发现")
        }
    }

    @ViewBuilder
    private var searchResultsContent: some View {
        if isSearching && searchResults.isEmpty {
            Spacer()
            ProgressView()
            Spacer()
        } else if let error = searchError, searchResults.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Text(error)
                    .foregroundStyle(.secondary)
                Button("重试") { performSearch(initial: true) }
            }
            Spacer()
        } else if searchResults.isEmpty {
            Spacer()
            Text("没有找到「\(keyword)」相关的有声书")
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            List {
                ForEach(searchResults) { album in
                    NavigationLink {
                        AlbumScreen(album: album)
                    } label: {
                        AlbumRow(album: album)
                    }
                }
                if searchHasMore {
                    ProgressView()
                        .onAppear { performSearch(initial: false) }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
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
                NavigationLink {
                    AlbumScreen(album: album)
                } label: {
                    AlbumRow(album: album)
                }
            }
            if viewModel.hasMore {
                ProgressView()
                    .onAppear {
                        Task { await viewModel.loadMore() }
                    }
            }
        }
        .listStyle(.plain)
        .task {
            if let container = appContainer {
                viewModel.attach(apiClient: container.apiClient)
            }
            await viewModel.loadRank(section: selectedSection)
        }
    }

    private func performSearch(initial: Bool) {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        guard let router = appContainer?.sourceRouter else { return }

        if initial {
            searchMode = true
            isSearching = true
            searchError = nil
            searchPage = 1
            searchResults = []
        } else if !searchHasMore { return }

        Task {
            do {
                // Search across all enabled sources and aggregate
                var allResults: [Album] = []
                let sources = [SourceRegistry.TINGYOU, SourceRegistry.TING15, SourceRegistry.TING08, SourceRegistry.YTYXSX, SourceRegistry.MEKUI]
                for src in sources {
                    let items = try await router.search(src: src, keyword: kw)
                    allResults.append(contentsOf: items)
                }
                if initial {
                    searchResults = allResults
                } else {
                    searchResults.append(contentsOf: allResults)
                }
                searchHasMore = false // Multi-source search doesn't paginate in this simplified model
                isSearching = false
            } catch let error as AntibotException {
                pendingKeyword = error.keyword.isEmpty ? kw : error.keyword
                showAntibotSheet = true
                isSearching = false
            } catch {
                searchError = "搜索失败：\(error.localizedDescription)"
                isSearching = false
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
