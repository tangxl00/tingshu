import SwiftUI

/// 发现页（build 22 · 对齐安卓 v1.3.3；v1.4.1 音源整合改造）：
/// 浏览区支持音源选择（听友FM 主源 + B站 + 59听书网，后两者受「我的→音源管理」开关控制），
/// 选中音源后分类 chips 与书籍列表切换为该源数据；点书经 NavigationLink 直达
/// AlbumScreen（章节即载、点章即播），无任何导入/预览中间页。
/// 「哪些源参与搜索」仍由「我的→音源管理」开关控制（AggregateSearcher）。
/// 分类二级折叠保留（build 21 · 反馈 6）。
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
    /// v1.4.2 · 悦听安全验证迁移：反爬拦截不再弹验证窗（入口迁至 我的→音源管理），
    /// 命中拦截时置位，由搜索结果/错误提示区展示引导文案。
    @State private var verifyHint = false
    /// build 21 · 反馈 7：发现页搜索框同步写入搜索历史
    private let historyStore = SearchHistoryStore()
    /// build 27：发现页搜索历史展示（页内变更即时刷新；形态参考 SearchScreen.historySection）
    @State private var history: [String] = []
    /// v1.4.1：浏览区当前音源（听友FM / B站 / 59听书网），默认主源
    @State private var browseSource = SourceRegistry.TINGYOU

    let onOpenAlbum: (Int64) -> Void
    let onOpenPlayer: () -> Void

    /// v1.4.1：浏览区可选音源——听友FM（主源，始终在列）+
    /// B站 / 59听书网（「我的→音源管理」开关关闭时不出现在选择器中，默认开）。
    private var browseSources: [(id: String, name: String)] {
        var result: [(id: String, name: String)] = [
            (SourceRegistry.TINGYOU, SourceRegistry.displayName(src: SourceRegistry.TINGYOU))
        ]
        if appContainer?.sourceEnabledStore.isEnabled(SourceRegistry.BILI) ?? true {
            result.append((SourceRegistry.BILI, SourceRegistry.displayName(src: SourceRegistry.BILI)))
        }
        if appContainer?.sourceEnabledStore.isEnabled(SourceRegistry.TING59) ?? true {
            result.append((SourceRegistry.TING59, SourceRegistry.displayName(src: SourceRegistry.TING59)))
        }
        return result
    }

    /// 当前浏览音源显示名（源被开关下线后仍能显示原名，回落由 onAppear 处理）
    private var browseSourceName: String {
        browseSources.first(where: { $0.id == browseSource })?.name
            ?? SourceRegistry.displayName(src: browseSource)
    }

    /// 当前音源的分类清单（原始分类结构）
    private var categories: [DiscoverCategory] {
        DiscoverCatalog.categories(for: browseSource)
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
                            verifyHint = false
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
                    libraryContent
                }
            }
            .navigationTitle(searchMode ? "搜索" : "发现")
            .onAppear {
                history = historyStore.all
                // v1.4.1：音源管理开关可能已变化——当前浏览源被关闭时回落主源
                if browseSource != SourceRegistry.TINGYOU,
                   !browseSources.contains(where: { $0.id == browseSource }) {
                    browseSource = SourceRegistry.TINGYOU
                    selectedCategoryId = DiscoverCatalog.categories(for: SourceRegistry.TINGYOU).first?.id ?? "recommend"
                    Task { await loadCurrent() }
                }
            }
        }
        // v1.4.2 · 悦听安全验证迁移：发现页不再挂验证 sheet——
        // 命中 AntibotException 时仅置 verifyHint，由搜索结果/错误提示区
        // 显示「请前往 我的→音源管理 完成验证」引导文案（验证入口已迁至该页）。
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

    /// v1.4.1：按所选音源加载——听友FM 走 rank 榜单（沿用 DiscoverViewModel.tingyouRank）；
    /// B站 / 59听书网走分类路由（LoadTarget.category → SourceRouter.discoverCategory），
    /// 两源共用现有的翻页 / 加载更多 / 失败重试机制。
    private func loadCurrent() async {
        guard let cat = selectedCategory else { return }
        if browseSource == SourceRegistry.TINGYOU {
            await viewModel.load(target: .tingyouRank(section: cat.id))
        } else {
            await viewModel.load(target: .category(src: browseSource, categoryId: cat.id))
        }
    }

    /// v1.4.1：切换浏览音源——分类重置为该源第一个，列表重新加载
    private func switchBrowseSource(_ src: String) {
        guard src != browseSource else { return }
        browseSource = src
        selectedCategoryId = DiscoverCatalog.categories(for: src).first?.id ?? ""
        categoryExpanded = false
        Task { await loadCurrent() }
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
                // v1.4.2 · 悦听安全验证迁移：拦截不弹窗，列表头部给引导文案
                //（其余源有结果时用户仍可继续浏览，悦听结果待验证后可见）
                if verifyHint {
                    Text("悦听有声书需要安全验证，请前往「我的→音源管理」完成验证后重试")
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
        // v1.4.1：分类面板标题行新增音源选择 Menu（音源：X ▾）——
        // 听友FM（DiscoverCatalog 5 榜单分类）/ B站（BiliCategories.ALL 6 分类）/
        // 59听书网（Ting59Categories.ALL 24 分类）；选中后下方分类与书籍列表切换为该源数据。
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
                    Menu {
                        ForEach(browseSources, id: \.id) { src in
                            Button {
                                switchBrowseSource(src.id)
                            } label: {
                                if src.id == browseSource {
                                    Label(src.name, systemImage: "checkmark")
                                } else {
                                    Text(src.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("音源：\(browseSourceName)")
                                .font(.subheadline)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
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
            verifyHint = false
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
            // v1.4.2 · 悦听安全验证迁移：反爬拦截不再弹窗——置提示态由结果区展示引导文案；
            // 无结果时直接给可操作文案（点重试前先去 我的→音源管理 完成验证）
            if outcome.antibotKeyword != nil {
                verifyHint = true
                if outcome.albums.isEmpty {
                    searchError = "悦听有声书需要安全验证，请前往「我的→音源管理」完成验证后重试"
                }
            }
            if outcome.allFailed && searchError == nil {
                searchError = "搜索失败：所有启用音源均不可用，请稍后重试"
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
