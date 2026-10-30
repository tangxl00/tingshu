import SwiftUI
import UIKit

/// 发现页（build 22 · 对齐安卓 v1.3.3；v1.4.1 音源整合改造）：
/// 浏览区支持音源选择（听友FM 主源 + B站 + 59听书网，后两者受「我的→音源管理」开关控制），
/// 选中音源后分类 chips 与书籍列表切换为该源数据；点书经 NavigationLink 直达
/// AlbumScreen（章节即载、点章即播），无任何导入/预览中间页。
/// 「哪些源参与搜索」仍由「我的→音源管理」开关控制（AggregateSearcher）。
/// build 48 · 需求 2：分类折叠面板已删——横向分类标签栏常驻（音源切换联动）。
/// build 48 · 需求 1：历史搜索区改为「聚焦才显示 + 全量换行显示」——截断
/// 分支（≤8 条自然高度 / >8 条 ScrollView 160pt）删除，聚焦判定隔离在叶子视图。
/// 搜索框：聚合全部启用音源（AggregateSearcher，与搜索页同一套逻辑）。
struct DiscoverScreen: View {
    @Environment(\.appContainer) private var appContainer
    @State private var viewModel = DiscoverViewModel()
    @State private var selectedCategoryId = "recommend"
    /// build 48 · 需求 1：搜索框聚焦态——历史搜索区「点击才显示」的显隐开关
    ///（聚焦 && 未输入 → 显示；失焦 / 输入中 / 搜索结果态 → 隐藏不占位）。
    /// build 41 教训评估：当时删 @FocusState 的根因是「聚焦翻转触发全 body
    /// 重渲染，键盘弹起时点书行的 NavigationLink 激活被同帧布局扰动丢弃」。
    /// b48 需求明确要求聚焦显隐，重新引入——但收焦动作仍走全局 window 级
    /// recognizer（resignFirstResponder，零额外重渲染），FocusState 只读显隐
    /// 不做收焦驱动；行导航回归由 DiscoverNavigationUITests A/B 真实点击守卫。
    @FocusState private var searchFieldFocused: Bool
    @State private var keyword = ""
    @State private var searchMode = false
    @State private var searchResults: [Album] = []
    @State private var isSearching = false
    @State private var searchError: String?
    /// build 21 · 反馈 5（Bug C）：逐源容错搜索——失败源收集并如实提示，不拖垮整体
    @State private var failedSources: [String] = []
    @State private var searchHasMore = false
    @State private var searchPage = 1
    /// build 21 · 反馈 7：发现页搜索框同步写入搜索历史
    private let historyStore = SearchHistoryStore()
    /// v1.4.3 · 需求 2：搜索历史展示（build 41 · 反馈 ① 收焦方式重构）：
    /// 此前由 FocusState 驱动——但 FocusState 状态翻转收焦会触发全 body 重渲染，
    /// 键盘弹起时点书行，「移除条件视图 + List 布局同帧扰动」会丢弃进行中的
    /// NavigationLink 行激活（四轮手势挂点修复无效的真根因，搜索页用 UIKit
    /// resignFirstResponder 零重渲染所以从未出问题）。build 41 删除 FocusState，
    /// 显隐改为 keyword 驱动：keyword 为空且非搜索结果态显示历史，输入中或
    /// 提交搜索（searchResultsContent 占位）即隐藏。
    /// build 27：发现页搜索历史展示（页内变更即时刷新；形态参考 SearchScreen.historySection）
    @State private var history: [String] = []
    /// build 41 · 反馈 ①：删除 FocusState——收焦统一走 UIKit resignFirstResponder
    ///（零重渲染，不打断进行中的 NavigationLink 行激活）。历史区块显隐改由
    /// keyword 驱动（见 history 声明处注释）。
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
                    // build 48 · 需求 1：搜索框抽为叶子视图——焦点态的「读」收敛
                    // 到 DiscoverSearchField / DiscoverHistoryGate 两个叶子内，
                    // DiscoverScreen.body 自身不读 searchFieldFocused：
                    // 焦点翻转只重渲染叶子，不波及书库 List 的行激活
                    //（build 41 真机回归根因：全 body 重渲染丢弃行导航激活）。
                    DiscoverSearchField(
                        keyword: $keyword,
                        focused: $searchFieldFocused,
                        onSubmit: { performSearch(initial: true) }
                    )
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
                // build 46 · 反馈 2（布局）：搜索栏内外纵向 padding 8 → 4——
                // 压缩「发现」大标题与搜索栏、搜索栏与历史区之间的留白
                //（真机反馈：搜索框整体上移、压缩顶部空白）。
                .padding(.vertical, 4)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.vertical, 4)
                // build 45 · 反馈 4：此前的「搜索栏容器 simultaneousGesture +
                // 间距区 onTapGesture」两处局部收焦挂载已删除——全局收键盘改走
                // window 级 UIKit recognizer（GlobalKeyboardDismiss，
                // cancelsTouchesInView=false 不吞事件），不再需要局部挂载。

                // build 41 · 反馈 ① 注释（build 43 更新；build 45 全局化）：
                // 容器级 tap 手势被 build 42 CI 六用例证伪（杀死 List 行
                // NavigationLink 激活）。build 45 起收焦不再依赖任何局部手势：
                // ① List 滚动收焦：scrollDismissesKeyboard(.immediately)（保留）；
                // ② 全局点空白收焦：window 级 UITapGestureRecognizer +
                //    endEditing（cancelsTouchesInView=false，不吞行点击事件）；
                // ③ 行点击：导航 push 本身收键盘（iOS 默认行为，无需代码）。
                if searchMode && !keyword.isEmpty {
                    searchResultsContent
                } else {
                    // build 48 · 需求 1：历史搜索区「点击才显示」——仅当搜索框
                    // 聚焦且未输入关键词时挂载（失焦/输入中/搜索结果态均不显示、
                    // 不占位）。挂载条件读在 DiscoverHistoryGate 叶子内，
                    // 主视图 body 不读焦点态（build 41 教训：焦点翻转引发的
                    // 重渲染必须局限在叶子，不能波及书库行导航激活）。
                    DiscoverHistoryGate(
                        focused: $searchFieldFocused,
                        keywordIsEmpty: keyword.isEmpty,
                        content: historySection
                    )
                    libraryContent
                }
            }
            .navigationTitle(searchMode ? "搜索" : "发现")
            // build 47 · 反馈 2（布局返修·用户可感知标准）：「发现」大标题改
            // 内联小标题——导航栏从大字标题形态（额外 ~52pt 标题行高）收敛为
            // 栏内小字标题，搜索框上移约一个标题行的高度（b46 仅压 4~8pt
            // padding，真机不可感知——本轮按「一眼可见」标准重做）。
            .navigationBarTitleDisplayMode(.inline)
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
        // v1.4.2 · 悦听安全验证迁移 → build 45 · 反馈 3：悦听（ytysxs）全链摘除——
        // verifyHint / verify sheet / AntibotException 闭环整体删除
        //（不再有反爬验证源，存量悦听书播放走 describePlaybackError 提示）。
    }

    // MARK: - 搜索历史（build 27：发现页可达展示）

    /// 「最近搜索」区块（build 36 · 反馈 3 返修）：条目改为不滚动的自适应换行
    /// 胶囊 chip 流式排布（LazyVGrid adaptive，一行放不下自动折到下一行）——
    /// 点 chip 主体直接填入并搜索、尾部 xmark 单条删除、一键清空保留；
    /// 交互不变，仅纵向列表 → 多行自适应排布。
    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            // build 44 · 反馈 4（历史搜索「依旧被截断」）→ build 45 · 反馈 2 返修：
            // b44 把 chip 文字改成 fixedSize(horizontal: false, vertical: true)
            //（允许宽度任意压缩）+ 去 lineLimit——LazyVGrid adaptive(minimum: 44)
            // 顺势把 chip 压到 44pt 单字宽，逐字竖排、模糊不可读（真机 b44 截图，
            // b44 自引入回归）。
            // build 45 修复：对齐 SearchScreen.historySection 的既有线上形态
            //（build 36 以来无截断/无竖排投诉）：Text lineLimit(1) + chip 整体
            // .fixedSize()——chip 报告完整固有宽度（长词单行完整显示不截断，
            // b44 反馈 4 的诉求保留），grid 列宽自适应、一行放不下整颗 chip
            // 折到下一行（多行流式排布，b44 反馈 4 的另一半诉求保留）。
            // build 48 · 需求 1（历史搜索全面显示）：删除 b47 的「≤8 条自然高度
            // / >8 条 ScrollView 160pt 限高」截断分支——历史条目无论多少一律
            // 全量换行显示（chip 流式排布自增高，不截断、不出现内嵌滚动）。
            historyList
        }
    }

    /// 历史区内容（标题行 + chip 流式网格）——build 47 从 ScrollView 拆出、
    /// build 48 起为全量渲染的唯一实现（截断分支已删）。
    private var historyList: some View {
        // build 44 · 反馈 4（历史搜索「依旧被截断」）→ build 45 · 反馈 2 返修：
        // b44 把 chip 文字改成 fixedSize(horizontal: false, vertical: true)
        //（允许宽度任意压缩）+ 去 lineLimit——LazyVGrid adaptive(minimum: 44)
        // 顺势把 chip 压到 44pt 单字宽，逐字竖排、模糊不可读（真机 b44 截图，
        // b44 自引入回归）。
        // build 45 修复：对齐 SearchScreen.historySection 的既有线上形态
        //（build 36 以来无截断/无竖排投诉）：Text lineLimit(1) + chip 整体
        // .fixedSize()——chip 报告完整固有宽度（长词单行完整显示不截断，
        // b44 反馈 4 的诉求保留），grid 列宽自适应、一行放不下整颗 chip
        // 折到下一行（多行流式排布，b44 反馈 4 的另一半诉求保留）。
        VStack(alignment: .leading, spacing: 6) {
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
            // build 49 · 问题 2（历史搜索词条重叠）：LazyVGrid adaptive 等宽列
            // → FlowLayout 流式布局。根因：adaptive 列宽按「可用宽 ÷ (44+8)」
            // 等宽切列（~53pt/列），chip 带 .fixedSize() 报告完整固有宽度
            //（「凡人修仙传」~130pt），超出列宽即以列锚点溢出渲染——相邻列
            // chip 横向叠压（真机取证：两颗词条叠进同一胶囊、只露一个删除钮）。
            // FlowLayout 逐 chip 按固有宽度累进放置，折行由累进坐标唯一决定，
            // 数学上不可能重叠；水平 8 / 垂直 6 对齐原 LazyVGrid 的列距行距。
            // chip 自身形态（lineLimit(1) + 整体 .fixedSize() 横排）不变——
            // b44 竖排回归防线（Build45FeedbackTests 守卫）继续生效。
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(history, id: \.self) { kw in
                    // chip 主体点选 = 填入并直接搜索；尾部 xmark 独立按钮 = 单条删除
                    HStack(spacing: 4) {
                        Button {
                            keyword = kw
                            performSearch(initial: true)
                        } label: {
                            Text(kw)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(.systemGray5)))
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal)
        // build 47：纵向 padding 4——历史区与搜索栏之间、历史区与书库分类栏
        // 之间各 4pt，合计 8pt ≤16pt（标准列表分区级间距）。
        .padding(.vertical, 4)
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

    /// v1.4.1：切换浏览音源——分类重置为该源第一个，列表重新加载；
    /// build 48 · 需求 2：折叠面板删除后无需收起动作，categories 计算
    /// 属性随 browseSource 变化自动刷新标签栏。
    private func switchBrowseSource(_ src: String) {
        guard src != browseSource else { return }
        browseSource = src
        selectedCategoryId = DiscoverCatalog.categories(for: src).first?.id ?? ""
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
                // build 42 · 任务一：行 identifier 供 DiscoverNavigationUITests
                // 真实点击复现「点书不导航」（键盘弹起 / 冷启动两场景）。
                ForEach(Array(searchResults.enumerated()), id: \.element.id) { idx, album in
                    NavigationLink {
                        AlbumScreen(album: album)
                    } label: {
                        AlbumRow(album: album)
                    }
                    .accessibilityIdentifier("discover_search_row_\(idx)")
                }
                if searchHasMore {
                    ProgressView()
                        .onAppear { performSearch(initial: false) }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            // build 41：List 本体不挂手势——收焦统一由内容区外层容器级
            // simultaneousGesture 处理（resignFirstResponder 零重渲染）。
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        // build 21 · 反馈 6 的分类折叠面板已在 build 48 · 需求 2 删除——
        // 「分类：热门推荐」入口按钮不再存在，横向分类标签栏常驻显示
        //（沿用原展开态样式：选中粗体主色 / 未选中次级色，横向滚动）；
        // 音源选择 Menu 迁至标签栏行首保留（听友FM 5 榜单分类 /
        // B站 BiliCategories 6 分类，build 38 起 59听书网已下架）。
        // 分类数据源 categories 取自当前 browseSource——音源切换后
        // 标签栏随之刷新（switchBrowseSource 重置 selectedCategoryId）。
        VStack(spacing: 0) {
            HStack(spacing: 8) {
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(categories) { cat in
                            Button(cat.name) {
                                selectedCategoryId = cat.id
                                Task { await loadCurrent() }
                            }
                            .fontWeight(selectedCategoryId == cat.id ? .bold : .regular)
                            .foregroundStyle(selectedCategoryId == cat.id ? .primary : .secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)

            if let error = viewModel.loadError {
                VStack(spacing: 12) {
                    Spacer()
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await loadCurrent() } }
                    Spacer()
                }
                // build 45 · 反馈 4：b43 的加载错误占位区收焦挂载已删除——
                // 全局 window 级 recognizer 兜底（sim 删除后「重试」Button 照常）。
            } else {
                List {
                    // build 42 · 任务一：行 identifier 供 DiscoverNavigationUITests
                    // 真实点击复现「点书不导航」——冷启动场景（用例 A）即点击
                    // discover_album_row_0，断言 AlbumScreen 推入。
                    ForEach(Array(viewModel.albums.enumerated()), id: \.element.id) { idx, album in
                        NavigationLink {
                            AlbumScreen(album: album)
                        } label: {
                            AlbumRow(album: album)
                        }
                        .accessibilityIdentifier("discover_album_row_\(idx)")
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
                .scrollDismissesKeyboard(.immediately)
                // build 41：List 本体不挂手势——收焦统一由内容区外层容器级
                // simultaneousGesture 处理（同 searchResultsContent）。
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

    /// build 41 · 收焦实现（build 43 沿用）：UIKit resignFirstResponder 零重渲染。
    /// build 45 · 反馈 4：五处局部挂载全删后已无调用点，方法一并移除——
    /// 全局收焦走 GlobalKeyboardDismiss（window 级 endEditing）。

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
            // 被反爬拦截或全源失败的搜索词同样落库（原「至少一源有结果才记」
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
            // build 51 · P1-1（质检必修）：增量回填——先到的源先上屏
            let outcome = await searcher.search(keyword: kw) { partial in
                searchResults = partial.albums
                failedSources = partial.failedSourceNames
            }
            searchResults = outcome.albums
            failedSources = outcome.failedSourceNames
            searchHasMore = false // 多源聚合首页后不再翻页（与旧行为一致）
            isSearching = false
            if outcome.allFailed {
                searchError = "搜索失败：所有启用音源均不可用，请稍后重试"
            }
        }
    }

    // MARK: - build 48 · 需求 1：焦点态隔离叶子视图

    /// 搜索框叶子视图（焦点态绑定收口点）。
    ///
    /// build 41 真机回归：@FocusState 状态翻转触发 DiscoverScreen 全 body
    /// 重渲染，丢弃进行中的 NavigationLink 行激活（点书无反应）。b48 需求
    /// 明确要求「聚焦才显示历史区」，故保留 @FocusState，但把焦点态的读写
    /// 全部隔离在本视图与 DiscoverHistoryGate 两个叶子内——DiscoverScreen.body
    /// 只写不读焦点态，焦点翻转的重渲染范围止于叶子，不波及书库行激活。
    private struct DiscoverSearchField: View {
        @Binding var keyword: String
        @FocusState.Binding var focused: Bool
        let onSubmit: () -> Void

        var body: some View {
            TextField("搜索书名 / 作者 / 主播", text: $keyword)
                .submitLabel(.search)
                // build 42 · 任务一：XCUITest 点击探针（DiscoverNavigationUITests 定位用）
                .accessibilityIdentifier("discover_search_field")
                // build 48 · 需求 1：聚焦态绑定——仅驱动历史搜索区显隐；
                // 收焦动作本身仍走全局 window 级 recognizer，不由此处驱动。
                .focused($focused)
                .onSubmit {
                    onSubmit()
                }
        }
    }

    /// 历史搜索区显隐门卫（叶子视图 · 焦点读隔离）。
    ///
    /// 仅「聚焦 && 关键词为空」渲染历史内容，否则完全不渲染（不占位）。
    /// 焦点态以 FocusState.Binding 下传——只有本视图读焦点，主视图不读。
    private struct DiscoverHistoryGate<Content: View>: View {
        @FocusState.Binding var focused: Bool
        let keywordIsEmpty: Bool
        let content: Content

        var body: some View {
            if focused && keywordIsEmpty {
                content
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
