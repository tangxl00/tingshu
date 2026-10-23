import SwiftUI

// build 29 · 59听书网主页：承载搜索 + 分类浏览双 Tab。
// 点击结果跳到导入页（带书ID）完成详情解析与导入。

struct Ting59HomeScreen: View {
    @Environment(\.appContainer) private var container
    @State private var tab = 0
    @State private var keyword = ""
    @State private var searchResults: [Ting59Adapter.Ting59SearchItem] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var selectedCategory: Ting59Category? = Ting59Categories.ALL.first
    @State private var categoryResults: [Ting59Adapter.Ting59SearchItem] = []
    @State private var isLoadingCategory = false
    @State private var categoryError: String?

    let onBack: () -> Void
    let onOpenItem: (Ting59Adapter.Ting59SearchItem) -> Void

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
                    ting59SearchContent
                } else {
                    ting59CategoryContent
                }
            }
            .navigationTitle("59听书网")
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
    private var ting59SearchContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索 59听书网书籍（书名 / 播音）", text: $keyword)
                    .submitLabel(.search)
                    .onSubmit { performSearch() }
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
                    Button("重试") { performSearch() }
                }
                Spacer()
            } else if searchResults.isEmpty {
                Spacer()
                Text("输入关键词开始搜索")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(searchResults, id: \.id) { item in
                        Button {
                            onOpenItem(item)
                        } label: {
                            ting59ResultRow(item: item)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func performSearch() {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        isSearching = true
        searchError = nil
        searchResults = []
        Task {
            do {
                let adapter = Ting59Adapter()
                let result = try await adapter.search(query: kw, page: 1)
                searchResults = result.list
            } catch {
                searchError = "搜索失败：\(error.localizedDescription)"
            }
            isSearching = false
        }
    }

    // MARK: - 分类

    @ViewBuilder
    private var ting59CategoryContent: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Ting59Categories.ALL) { cat in
                        Button(cat.name) {
                            selectedCategory = cat
                            loadCategory(cat: cat)
                        }
                        .fontWeight(selectedCategory?.id == cat.id ? .bold : .regular)
                        .foregroundStyle(selectedCategory?.id == cat.id ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedCategory?.id == cat.id ? Color(.systemGray5) : Color.clear)
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
                    ForEach(categoryResults, id: \.id) { item in
                        Button {
                            onOpenItem(item)
                        } label: {
                            ting59ResultRow(item: item)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func loadCategory(cat: Ting59Category) {
        isLoadingCategory = true
        categoryError = nil
        categoryResults = []
        Task {
            do {
                let adapter = Ting59Adapter()
                let result = try await adapter.category(categoryId: cat.id, page: 1)
                categoryResults = result.books
            } catch {
                categoryError = "加载失败：\(error.localizedDescription)"
            }
            isLoadingCategory = false
        }
    }

    // MARK: - 结果行

    private func ting59ResultRow(item: Ting59Adapter.Ting59SearchItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).lineLimit(2).font(.subheadline)
                let subtitle = [item.narrator.map { "播音：\($0)" },
                                item.author.map { "作者：\($0)" },
                                item.category]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
                if let update = item.updateTime {
                    Text(update).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 59听书网分类模型

struct Ting59Category: Identifiable, Sendable {
    let id: String
    let name: String
}

enum Ting59Categories {
    static let ALL: [Ting59Category] = [
        Ting59Category(id: "xuanhuan", name: "玄幻"),
        Ting59Category(id: "wuxia", name: "武侠"),
        Ting59Category(id: "dushi", name: "都市"),
        Ting59Category(id: "yanqing", name: "言情"),
        Ting59Category(id: "chuanyue", name: "穿越"),
        Ting59Category(id: "kongbu", name: "恐怖"),
        Ting59Category(id: "lishi", name: "历史"),
        Ting59Category(id: "youxi", name: "网游"),
        Ting59Category(id: "lingyi", name: "灵异"),
        Ting59Category(id: "zhentan", name: "侦探"),
        Ting59Category(id: "jingji", name: "军事"),
        Ting59Category(id: "xianxia", name: "仙侠"),
        Ting59Category(id: "qihuan", name: "奇幻"),
        Ting59Category(id: "keji", name: "科技"),
        Ting59Category(id: "jingji2", name: "经济"),
        Ting59Category(id: "jiaoyu", name: "教育"),
        Ting59Category(id: "ertong", name: "儿童"),
        Ting59Category(id: "jiankang", name: "健康"),
        Ting59Category(id: "shenghuo", name: "生活"),
        Ting59Category(id: "yuyan", name: "语言"),
        Ting59Category(id: "zhexue", name: "哲学"),
        Ting59Category(id: "zongjiao", name: "宗教"),
        Ting59Category(id: "falv", name: "法律"),
        Ting59Category(id: "zonghe", name: "综合"),
    ]
}
