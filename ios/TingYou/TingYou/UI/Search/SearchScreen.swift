import SwiftUI

/// 搜索页：全部已注册音源可选（tingyou / ting15 / ting08 / 悦听 / 书音FM），
/// 走 SourceRouter 真实路由；悦听命中反爬拦截时弹 YtysxsVerifySheet 人工验证（P0-4 完整闭环）。
/// build 21 · 反馈 7：搜索历史记忆——成功发起的搜索词本地保存（去重置顶、上限 20 条），
/// 空态显示历史列表，点击回填直接搜，支持单条删除与一键清空。
struct SearchScreen: View {
    @Environment(\.appContainer) private var appContainer
    @State private var keyword = ""
    @State private var selectedSrc = SourceRegistry.TINGYOU
    @State private var results: [Album] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var showAntibotSheet = false
    @State private var pendingKeyword = ""
    /// build 21 · 反馈 7：搜索历史（页内变更即时刷新）
    @State private var history: [String] = []
    private let historyStore = SearchHistoryStore()

    private let searchSources: [(id: String, name: String)] = [
        (SourceRegistry.TINGYOU, "听友FM"),
        (SourceRegistry.TING15, "听十五"),
        (SourceRegistry.TING08, "听吧"),
        (SourceRegistry.YTYXSX, "悦听有声书"),
        (SourceRegistry.MEKUI, "书音FM"),
    ]

    /// build 21 · 反馈 5（Bug C）：书音FM 搜索实测存在服务端拒绝场景（403/404 因网络环境而异），
    /// 错误文案如实区分，不伪装成「无结果」。
    private func describe(error: Error, src: String) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .badServerResponse:
                return "\(SourceRegistry.displayName(src: src)) 搜索暂时不可用（服务器拒绝），可稍后重试或切换其他音源"
            case .timedOut:
                return "\(SourceRegistry.displayName(src: src)) 访问过快被限流，请稍后再试"
            default:
                break
            }
        }
        return "搜索失败：\(error.localizedDescription)"
    }

    var body: some View {
        List {
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            if results.isEmpty && !isSearching {
                historySection
            }
            if isSearching && results.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(searchSources, id: \.id) { src in
                        Button {
                            selectedSrc = src.id
                        } label: {
                            if selectedSrc == src.id {
                                Label(src.name, systemImage: "checkmark")
                            } else {
                                Text(src.name)
                            }
                        }
                    }
                } label: {
                    Label(searchSources.first(where: { $0.id == selectedSrc })?.name ?? "音源",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                // 增强 4：音源选择按钮按压反馈
                .buttonStyle(.pressable)
                .foregroundStyle(Color.accentColor)
            }
        }
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

    private func search() async {
        guard !keyword.isEmpty else { return }
        guard let router = appContainer?.sourceRouter else { return }
        isSearching = true
        errorMessage = nil
        do {
            let albums = try await router.search(src: selectedSrc, keyword: keyword)
            results = albums
            // build 21 · 反馈 7：搜索词成功入列历史（去重置顶、上限 20）
            historyStore.add(keyword)
            history = historyStore.all
        } catch let error as AntibotException {
            pendingKeyword = error.keyword.isEmpty ? keyword : error.keyword
            showAntibotSheet = true // 引导人工验证（不自动破解）
        } catch let error as PaidChapterException {
            errorMessage = "该章节为付费内容，已拦截"
        } catch {
            errorMessage = describe(error: error, src: selectedSrc)
            print("Search error (\(selectedSrc)): \(error)")
        }
        isSearching = false
    }
}
