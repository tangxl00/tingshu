import SwiftUI

// build 29 · B站音源主页：从书库/书架的「B站音源」入口进入，承载搜索 + 分类浏览双 Tab。
// 点击结果跳到导入页完成详情解析与入库。
// 复用 BiliSearchApi.swift 中已定义的 BiliCategory / BiliCategories 模型。

struct BiliHomeScreen: View {
    @Environment(\.appContainer) private var container
    @State private var tab = 0
    @State private var keyword = ""
    @State private var searchResults: [BiliSearchApi.SearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var selectedCategory: BiliCategory? = BiliCategories.ALL.first
    @State private var categoryResults: [BiliSearchApi.SearchResult] = []
    @State private var isLoadingCategory = false
    @State private var categoryError: String?

    let onBack: () -> Void
    let onOpenImport: (String) -> Void

    private let titles = ["搜索", "分类"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(0..<titles.count, id: \.self) { idx in
                        Text(titles[idx]).tag(idx)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if tab == 0 {
                    biliSearchContent
                } else {
                    biliCategoryContent
                }
            }
            .navigationTitle("B站音源")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                    }
                }
            }
        }
    }

    // MARK: - 搜索

    @ViewBuilder
    private var biliSearchContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索B站有声视频", text: $keyword)
                    .submitLabel(.search)
                    .onSubmit { performBiliSearch() }
                if !keyword.isEmpty {
                    Button(action: { keyword = "" }) {
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

            if isSearching && searchResults.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = searchError, searchResults.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { performBiliSearch() }
                }
                Spacer()
            } else if searchResults.isEmpty {
                Spacer()
                Text("输入关键词搜索B站有声视频")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(searchResults, id: \.bvid) { item in
                        Button {
                            onOpenImport(item.bvid)
                        } label: {
                            biliResultRow(item: item)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func performBiliSearch() {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        guard let container = container else {
            searchError = "搜索服务未就绪"
            return
        }
        isSearching = true
        searchError = nil
        searchResults = []
        Task {
            do {
                let page = try await container.sourceRouter.biliSearchApi.searchAudiobooks(keyword: kw, page: 1)
                searchResults = page.items
            } catch {
                searchError = "搜索失败：\(error.localizedDescription)"
            }
            isSearching = false
        }
    }

    // MARK: - 分类

    @ViewBuilder
    private var biliCategoryContent: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BiliCategories.ALL) { cat in
                        Button(cat.name) {
                            selectedCategory = cat
                            loadCategory(cat: cat)
                        }
                        .fontWeight(selectedCategory?.key == cat.key ? .bold : .regular)
                        .foregroundStyle(selectedCategory?.key == cat.key ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedCategory?.key == cat.key ? Color(.systemGray5) : Color.clear)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            if isLoadingCategory && categoryResults.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = categoryError, categoryResults.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") {
                        if let cat = selectedCategory { loadCategory(cat: cat) }
                    }
                }
                Spacer()
            } else if categoryResults.isEmpty {
                Spacer()
                Text("该分类暂无内容")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(categoryResults, id: \.bvid) { item in
                        Button {
                            onOpenImport(item.bvid)
                        } label: {
                            biliResultRow(item: item)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func loadCategory(cat: BiliCategory) {
        isLoadingCategory = true
        categoryError = nil
        categoryResults = []
        Task {
            do {
                guard let container = container else {
                    categoryError = "搜索服务未就绪"
                    isLoadingCategory = false
                    return
                }
                let page = try await container.sourceRouter.biliSearchApi.searchAudiobooks(
                    keyword: cat.keywords.first ?? "有声小说",
                    page: 1
                )
                categoryResults = page.items
            } catch {
                categoryError = "加载失败：\(error.localizedDescription)"
            }
            isLoadingCategory = false
        }
    }

    // MARK: - 共用

    private func biliResultRow(item: BiliSearchApi.SearchResult) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: item.coverUrl, size: 70, source: SourceRegistry.BILI)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).lineLimit(2).font(.subheadline)
                Text("UP主：\(item.author)")
                    .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                if item.paid {
                    Text("付费/大会员")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.1), in: Capsule())
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
