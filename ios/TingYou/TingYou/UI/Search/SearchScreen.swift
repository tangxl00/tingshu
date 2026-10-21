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
            if results.isEmpty && !isSearching && errorMessage == nil {
                historySection
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

    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            Section {
                ForEach(history, id: \.self) { kw in
                    Button {
                        keyword = kw
                        Task { await search() }
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
                    .swipeActions {
                        Button(role: .destructive) {
                            historyStore.remove(kw)
                            history = historyStore.all
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
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

    private func search() async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        guard let container = appContainer else { return }

        isSearching = true
        errorMessage = nil
        failedSources = []

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
        } else if !outcome.albums.isEmpty {
            // build 21 · 反馈 7：搜索词成功入列历史（去重置顶、上限 20）
            historyStore.add(kw)
            history = historyStore.all
        }
        if let antibot = outcome.antibotKeyword {
            pendingKeyword = antibot
            showAntibotSheet = true // 引导人工验证（不自动破解）
        }
    }
}
