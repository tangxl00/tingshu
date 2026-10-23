import SwiftUI
import SwiftData

/// 发现页（build 22 · 对齐安卓 v1.3.3）：
/// 浏览模式固定展示主源（听友FM）的榜单/分类——音源切换菜单已移除，
/// 「哪些源参与搜索」由「我的→音源管理」开关控制（对齐安卓 LibraryScreen）。
/// 分类二级折叠保留（build 21 · 反馈 6，仅听友FM 分类）。
/// 搜索框：聚合全部启用音源（AggregateSearcher，与搜索页同一套逻辑）。
struct DiscoverScreen: View {
    @Environment(\.appContainer) private var appContainer
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = DiscoverViewModel()
    /// P0-4：导入完成后导航到专辑页
    @State private var navToAlbum: Album? = nil
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
    /// build 27：发现页搜索历史展示（页内变更即时刷新；形态参考 SearchScreen.historySection）
    @State private var history: [String] = []
    /// build 29：B站 / 59听书网入口卡片 sheet 状态
    @State private var showBiliHome = false
    @State private var showTing59Home = false
    @State private var showBiliImport = false
    @State private var biliImportBvid: String? = nil
    @State private var showTing59Import = false
    @State private var ting59ImportBookId: String? = nil

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
                    // build 27：搜索历史展示——关键词为空（未进入搜索模式）时显示「最近搜索」
                    // （SearchScreen 是死代码不可达，历史此前只写不读；现移到发现页可达）。
                    historySection
                    // build 29：B站 / 59听书网独立入口卡片
                    sourceEntryCards
                    libraryContent
                }
            }
            .navigationTitle(searchMode ? "搜索" : "发现")
            .onAppear { history = historyStore.all }
            .navigationDestination(item: $navToAlbum) { album in
                AlbumScreen(album: album)
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

    // MARK: - 搜索历史（build 27：发现页可达展示）

    /// 「最近搜索」区块：条目点选直接填入并搜索、单条删除（滑动）、一键清空。
    /// 形态对齐 SearchScreen.historySection 既有实现（复用 SearchHistoryStore）。
    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近搜索")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("清空") {
                        historyStore.clear()
                        history = []
                    }
                    .font(.caption)
                }
                ForEach(history, id: \.self) { kw in
                    // 行主体点选 = 填入并直接搜索；尾部 xmark 独立按钮 = 单条删除
                    //（swipeActions 是 List 专属修饰符，VStack 布局下不生效，故用显式删除按钮）
                    HStack {
                        Button {
                            keyword = kw
                            performSearch(initial: true)
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                Text(kw)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        Button {
                            historyStore.remove(kw)
                            history = historyStore.all
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color(.systemGray3))
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - build 29 · 音源入口卡片

    @ViewBuilder
    private var sourceEntryCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("更多音源")
                .font(.subheadline.bold())
                .padding(.horizontal)
            HStack(spacing: 12) {
                Button {
                    showBiliHome = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "play.rectangle.fill")
                                .foregroundStyle(.pink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("B站")
                            .font(.subheadline.bold())
                        Text("搜索有声视频")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button {
                    showTing59Home = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "headphones")
                                .foregroundStyle(.indigo)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("59听书网")
                            .font(.subheadline.bold())
                        Text("搜索/分类收听")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showBiliHome) {
            BiliHomeScreen(
                onBack: { showBiliHome = false },
                onOpenImport: { bvid in
                    biliImportBvid = bvid
                    showBiliImport = true
                }
            )
            .sheet(isPresented: $showBiliImport) {
                BiliImportScreen(
                    onBack: { showBiliImport = false },
                    onOpenAlbum: { src, bookId in
                        showBiliImport = false
                        let descriptor = FetchDescriptor<ImportedBookModel>(
                            predicate: #Predicate { $0.id == bookId }
                        )
                        if let book = try? modelContext.fetch(descriptor).first {
                            navToAlbum = Album(
                                albumId: bookId, title: book.title, author: nil, teller: nil,
                                coverUrl: nil, intro: nil, category: nil, categoryId: nil,
                                type: nil, typeId: nil, status: nil, chapterCount: nil,
                                updatedAt: nil, playCount: nil, available: true,
                                source: src, detailPath: book.meta
                            )
                        }
                    },
                    prefillBvid: biliImportBvid
                )
            }
        }
        .sheet(isPresented: $showTing59Home) {
            Ting59HomeScreen(
                onBack: { showTing59Home = false },
                onOpenItem: { item in
                    ting59ImportBookId = item.id
                    showTing59Import = true
                }
            )
            .sheet(isPresented: $showTing59Import) {
                Ting59ImportScreen(
                    onBack: { showTing59Import = false },
                    onOpenAlbum: { src, bookId in
                        showTing59Import = false
                        let descriptor = FetchDescriptor<ImportedBookModel>(
                            predicate: #Predicate { $0.id == bookId }
                        )
                        if let book = try? modelContext.fetch(descriptor).first {
                            navToAlbum = Album(
                                albumId: bookId, title: book.title, author: nil, teller: nil,
                                coverUrl: nil, intro: nil, category: nil, categoryId: nil,
                                type: nil, typeId: nil, status: nil, chapterCount: nil,
                                updatedAt: nil, playCount: nil, available: true,
                                source: src, detailPath: book.meta.map { "/mp3/\($0).html" }
                            )
                        }
                    },
                    prefillBookId: ting59ImportBookId
                )
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
                    if viewModel.loadMoreFailed {
                        // build 24（存量 P2）：加载更多失败的轻量反馈——不弹窗打断，
                        // 列表尾部一行提示 + 重试入口（成功后回到自动加载态）
                        HStack(spacing: 8) {
                            Text("加载更多失败").font(.caption).foregroundStyle(.orange)
                            Button("重试") { Task { await viewModel.loadMore() } }
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } else if viewModel.hasMore {
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
            // build 27：提交搜索时即记录（非空关键词即记，不依赖结果成败）——
            // 被悦听反爬拦截或全源失败的搜索词同样落库（原「至少一源有结果才记」
            // 会丢失被拦截场景的词，用户复搜无记忆）。
            historyStore.add(kw)
            history = historyStore.all
        } else if !searchHasMore { return }

        // build 27（闪退修复）：Task 闭包内直接改 @State 属非主线程改状态（未定义行为，
        // 录屏中验证流程触发崩溃疑似此因）——显式 @MainActor 隔离整块搜索状态更新。
        Task { @MainActor in
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
