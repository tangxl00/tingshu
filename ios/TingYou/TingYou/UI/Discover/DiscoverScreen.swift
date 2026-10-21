import SwiftUI

/// 发现页（build 22 · 对齐安卓 v1.3.3）：
/// 浏览模式固定展示主源（听友FM）的榜单/分类——音源切换菜单已移除，
/// 「哪些源参与搜索」由「我的→音源管理」开关控制（对齐安卓 LibraryScreen）。
/// 分类二级折叠保留（build 21 · 反馈 6，仅听友FM 分类）。
/// 搜索框：聚合全部启用音源（AggregateSearcher，与搜索页同一套逻辑）。
struct DiscoverScreen: View {
    @Environment(\.appContainer) private var appContainer
    @State private var viewModel = DiscoverViewModel()
    @State private var selectedCategoryId = "recommend"
    /// build 21 · 反馈 6：分类选择折叠面板（默认收起）
    @State private var categoryExpanded = false
    @State private var keyword = ""
    @State private var searchMode = false
    @State private var searchResults: [Album] = []
    @State private var isSearching = false
    @State private var searchError: String?
    /// build 21 · 反馈 5（Bug C）：逐源容错搜索——失败源收集并如实提示，不拖垮整体
    @State private var failedSources: [String] = []
    @State private var searchHasMore = false
    @State private var searchPage = 1
    @State private var showAntibotSheet = false
    @State private var pendingKeyword = ""
    /// build 21 · 反馈 7：发现页搜索框同步写入搜索历史
    private let historyStore = SearchHistoryStore()

    let onOpenAlbum: (Int64) -> Void
    let onOpenPlayer: () -> Void

    /// build 22：固定主源（听友FM）——发现页不再切源，对齐安卓 LibraryScreen
    private static let mainSource = SourceRegistry.TINGYOU

    /// 主源的分类清单（原始分类结构）
    private var categories: [DiscoverCategory] {
        DiscoverCatalog.categories(for: Self.mainSource)
    }

    private var selectedCategory: DiscoverCategory? {
        categories.first(where: { $0.id == selectedCategoryId })
    }

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
        // build 21 · Bug A 同类问题：发现页聚合搜索命中悦听反爬拦截时，
        // AntibotException 置位了 showAntibotSheet 但从未挂 .sheet（与播放器页同款遗漏）——补挂。
        .sheet(isPresented: $showAntibotSheet) {
            YtysxsVerifySheet(
                keyword: pendingKeyword,
                cookieStore: appContainer?.ytysxsCookieStore ?? KeychainTokenStore()) { verified in
                showAntibotSheet = false
                if verified {
                    performSearch(initial: true) // 验证通过后自动重试原搜索
                }
            }
        }
    }

    /// build 22：固定主源榜单加载（tingyou rank）
    private func loadCurrent() async {
        guard let cat = selectedCategory else { return }
        await viewModel.load(target: .tingyouRank(section: cat.id))
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
            VStack(spacing: 12) {
                Text("没有找到「\(keyword)」相关的有声书")
                    .foregroundStyle(.secondary)
                // build 21 · 反馈 5（Bug C）：部分源搜索失败时如实列出，而非静默空结果
                if !failedSources.isEmpty {
                    Text("以下音源本次搜索不可用：\(failedSources.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        } else {
            List {
                if !failedSources.isEmpty {
                    Text("以下音源本次搜索不可用：\(failedSources.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
        // build 21 · 反馈 6：分类选择折叠面板（二级折叠、默认收起）。
        // build 22：固定听友FM 分类（原始 5 个 rank section）。
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: $categoryExpanded) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(categories) { cat in
                            Button(cat.name) {
                                selectedCategoryId = cat.id
                                categoryExpanded = false
                                Task { await loadCurrent() }
                            }
                            .fontWeight(selectedCategoryId == cat.id ? .bold : .regular)
                            .foregroundStyle(selectedCategoryId == cat.id ? .primary : .secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
            } label: {
                HStack {
                    Text("分类：\(selectedCategory?.name ?? "全部")")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: categoryExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 4)

            if let error = viewModel.loadError {
                VStack(spacing: 12) {
                    Spacer()
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await loadCurrent() } }
                    Spacer()
                }
            } else {
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
            }
        }
        .task {
            if let container = appContainer {
                viewModel.attach(apiClient: container.apiClient,
                                 sourceRouter: container.sourceRouter)
            }
            if viewModel.albums.isEmpty {
                await loadCurrent()
            }
        }
    }

    /// build 22 · 对齐安卓：聚合搜索读 SourceEnabledStore 启用集（与搜索页同一套 AggregateSearcher）。
    private func performSearch(initial: Bool) {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        guard let container = appContainer else { return }

        if initial {
            searchMode = true
            isSearching = true
            searchError = nil
            failedSources = []
            searchPage = 1
            searchResults = []
        } else if !searchHasMore { return }

        Task {
            let searcher = AggregateSearcher(
                searcher: container.sourceRouter,
                enabledStore: container.sourceEnabledStore)
            if searcher.enabledSources.isEmpty {
                searchResults = []
                failedSources = []
                searchHasMore = false
                isSearching = false
                searchError = "没有可用的搜索源，请前往「我的→音源」启用至少一个"
                return
            }
            let outcome = await searcher.search(keyword: kw)
            searchResults = outcome.albums
            failedSources = outcome.failedSourceNames
            searchHasMore = false // 多源聚合首页后不再翻页（与旧行为一致）
            isSearching = false
            if outcome.allFailed {
                searchError = "搜索失败：所有启用音源均不可用，请稍后重试"
            } else if !outcome.albums.isEmpty {
                // build 21 · 反馈 7：发现页搜索成功也记入历史（至少一源有结果才算成功）
                historyStore.add(kw)
            }
            if let antibot = outcome.antibotKeyword {
                pendingKeyword = antibot
                showAntibotSheet = true
            }
        }
    }
}

struct AlbumRow: View {
    let album: Album
    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: album.coverUrl, size: 70, source: album.source)
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
