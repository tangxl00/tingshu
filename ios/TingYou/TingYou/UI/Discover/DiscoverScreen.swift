import SwiftUI

struct DiscoverScreen: View {
    @Environment(\.appContainer) private var appContainer
    @State private var viewModel = DiscoverViewModel()
    /// build 21 · 反馈 4：发现页音源选择（全局持久化，默认听友FM）
    @AppStorage("discover_selected_source") private var selectedSource = SourceRegistry.TINGYOU
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

    /// 当前源的分类清单（按原始音源结构）
    private var categories: [DiscoverCategory] {
        DiscoverCatalog.categories(for: selectedSource)
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
            .toolbar {
                // build 21 · 反馈 4：音源选择（与搜索页同级的全局选择）
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(DiscoverCatalog.sourceOptions, id: \.id) { opt in
                            Button {
                                switchSource(opt.id)
                            } label: {
                                if selectedSource == opt.id {
                                    Label(opt.name, systemImage: "checkmark")
                                } else {
                                    Text(opt.name)
                                }
                            }
                        }
                    } label: {
                        Label(
                            DiscoverCatalog.sourceOptions.first(where: { $0.id == selectedSource })?.name ?? "音源",
                            systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(Color.accentColor)
                }
            }
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

    /// build 21 · 反馈 4：切换音源——分类回到该源第一个，列表重新加载
    private func switchSource(_ src: String) {
        guard src != selectedSource else { return }
        selectedSource = src
        let cats = DiscoverCatalog.categories(for: src)
        selectedCategoryId = cats.first?.id ?? ""
        viewModel.albums = []
        viewModel.hasMore = false
        Task { await loadCurrent() }
    }

    private func loadCurrent() async {
        guard let cat = selectedCategory else { return }
        switch selectedSource {
        case SourceRegistry.TINGYOU:
            await viewModel.load(target: .tingyouRank(section: cat.id))
        default:
            await viewModel.load(target: .category(src: selectedSource, categoryId: cat.id))
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
        // 各源原始分类平铺会占满首屏（ting08 有 15 个），折叠收起后只占一行。
        if DiscoverCatalog.unsupportedSources.contains(selectedSource) {
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("该源暂不支持发现页")
                        .foregroundStyle(.secondary)
                    Text("可在搜索页使用该音源搜索，或切换其他音源浏览发现内容")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            }
        } else {
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
    }

    private func performSearch(initial: Bool) {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        guard let router = appContainer?.sourceRouter else { return }

        if initial {
            searchMode = true
            isSearching = true
            searchError = nil
            failedSources = []
            searchPage = 1
            searchResults = []
        } else if !searchHasMore { return }

        Task {
            // build 21 · 反馈 5（Bug C）：逐源容错——单源失败（如书音FM 403）不拖垮
            // 全源聚合，失败源名如实透出；悦听 AntibotException 仍走人工验证闭环。
            var allResults: [Album] = []
            var failed: [String] = []
            var antibotKeyword: String?
            let sources = [SourceRegistry.TINGYOU, SourceRegistry.TING15, SourceRegistry.TING08, SourceRegistry.YTYXSX, SourceRegistry.MEKUI]
            for src in sources {
                do {
                    let items = try await router.search(src: src, keyword: kw)
                    allResults.append(contentsOf: items)
                } catch let error as AntibotException {
                    antibotKeyword = error.keyword.isEmpty ? kw : error.keyword
                } catch {
                    failed.append(SourceRegistry.displayName(src: src))
                }
            }
            searchResults = allResults
            failedSources = failed
            searchHasMore = false // 多源聚合首页后不再翻页（与旧行为一致）
            isSearching = false
            // build 21 · 反馈 7：发现页搜索成功也记入历史（至少一源有结果才算成功）
            if !allResults.isEmpty { historyStore.add(kw) }
            if let kw2 = antibotKeyword {
                pendingKeyword = kw2
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
