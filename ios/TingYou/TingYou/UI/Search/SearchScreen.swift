import SwiftUI

/// 搜索页（build 22 · 对齐安卓 v1.3.3）：
/// 一次搜索聚合「全部启用音源」的结果（AggregateSearcher，
/// 范围 = SourceEnabledStore 启用集，「我的→音源管理」开关真正控制搜索范围）。
/// 单源失败如实透出源名、悦听反爬弹 YtysxsVerifySheet 人工验证、全源失败才报整体错误。
/// build 21 · 反馈 7：搜索历史记忆——成功发起的搜索词本地保存（去重置顶、上限 20 条）。
struct SearchScreen: View {
    @Environment(\.appContainer) private var appContainer
    @State private var keyword = ""
    @State private var results: [Album] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    /// build 22：聚合搜索失败源透出（单源失败不拖垮整体）
    @State private var failedSources: [String] = []
    @State private var showAntibotSheet = false
    @State private var pendingKeyword = ""
    /// build 21 · 反馈 7：搜索历史（页内变更即时刷新）
    @State private var history: [String] = []
    private let historyStore = SearchHistoryStore()

    var body: some View {
        List {
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            // build 28 · 搜索输入联动历史建议：输入非空时展示匹配历史词；
            // 输入为空时维持既有「最近搜索」分区。
            if results.isEmpty && !isSearching && errorMessage == nil {
                if keyword.isEmpty {
                    historySection
                } else {
                    suggestionsSection
                }
            }
            if isSearching && results.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            if !failedSources.isEmpty && !(results.isEmpty && isSearching) {
                Text("以下音源本次搜索不可用：\(failedSources.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(results) { album in
                NavigationLink {
                    AlbumScreen(album: album)
                } label: {
                    AlbumRow(album: album)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $keyword)
        .onSubmit(of: .search) {
            Task { await search() }
        }
        .onAppear { history = historyStore.all }
        .navigationTitle("搜索")
        .sheet(isPresented: $showAntibotSheet) {
            YtysxsVerifySheet(
                keyword: pendingKeyword,
                cookieStore: appContainer?.ytysxsCookieStore ?? KeychainTokenStore()) { verified in
                    showAntibotSheet = false
                    if verified {
                        Task { await search() } // 验证通过后自动重试原搜索
                    }
                }
        }
    }

    // MARK: - 搜索历史（build 21 · 反馈 7）

    /// build 28 · 输入联动历史建议：与输入匹配的历史词，点击直接搜索。
    @ViewBuilder
    private var suggestionsSection: some View {
        let matches = historyStore.matching(keyword)
        if !matches.isEmpty {
            Section {
                ForEach(matches, id: \.self) { kw in
                    Button {
                        keyword = kw
                        Task { await search() }
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(kw)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            } header: {
                Text("历史建议")
            }
        }
    }

    /// build 36 · 反馈 3 返修：搜索历史改为不滚动的自适应换行胶囊 chip 流式
    /// 排布（LazyVGrid adaptive，一行放不下自动折行；与发现页形态对齐）；
    /// 点 chip 填入并搜索、xmark 单条删除、清空保留。
    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                    ForEach(history, id: \.self) { kw in
                        HStack(spacing: 4) {
                            Button {
                                keyword = kw
                                Task { await search() }
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
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(.systemGray5)))
                        .fixedSize()
                    }
                }
            } header: {
                HStack {
                    Text("最近搜索")
                    Spacer()
                    Button("清空") {
                        historyStore.clear()
                        history = []
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - 聚合搜索（build 22 · 对齐安卓）

    /// build 27（闪退修复）：@State 全路径主线程更新——显式 @MainActor
    ///（非隔离 async 上下文改 @State 是未定义行为，验证回调重入时序下疑似崩溃源）。
    @MainActor private func search() async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        guard let container = appContainer else { return }

        isSearching = true
        errorMessage = nil
        failedSources = []

        // build 27：提交搜索时即记录（与发现页同一语义——非空关键词即记，
        // 不依赖结果成败，被反爬拦截或全源失败的搜索词同样落库）
        historyStore.add(kw)
        history = historyStore.all

        // 启用集为空：对齐安卓「没有可用的搜索源」提示（零源防护在音源管理页兜底，此处不崩不假搜）
        let searcher = AggregateSearcher(
            searcher: container.sourceRouter, enabledStore: container.sourceEnabledStore)
        if searcher.enabledSources.isEmpty {
            isSearching = false
            errorMessage = "没有可用的搜索源，请前往「我的→音源」启用至少一个"
            return
        }

        let outcome = await searcher.search(keyword: kw)
        results = outcome.albums
        failedSources = outcome.failedSourceNames
        isSearching = false

        if outcome.allFailed {
            errorMessage = "搜索失败：所有启用音源均不可用，请稍后重试"
        }
        if let antibot = outcome.antibotKeyword {
            pendingKeyword = antibot
            showAntibotSheet = true // 引导人工验证（不自动破解）
        }
    }
}
