import SwiftUI

/// 搜索页：全部已注册音源可选（tingyou / ting15 / ting08 / 悦听 / 书音FM），
/// 走 SourceRouter 真实路由；悦听命中反爬拦截时弹 YtysxsVerifySheet 人工验证（P0-4 完整闭环）。
struct SearchScreen: View {
    @Environment(\.appContainer) private var appContainer
    @State private var keyword = ""
    @State private var selectedSrc = SourceRegistry.TINGYOU
    @State private var results: [Album] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var showAntibotSheet = false
    @State private var pendingKeyword = ""

    private let searchSources: [(id: String, name: String)] = [
        (SourceRegistry.TINGYOU, "听友FM"),
        (SourceRegistry.TING15, "听十五"),
        (SourceRegistry.TING08, "听吧"),
        (SourceRegistry.YTYXSX, "悦听有声书"),
        (SourceRegistry.MEKUI, "书音FM"),
    ]

    var body: some View {
        List {
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
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

    private func search() async {
        guard !keyword.isEmpty else { return }
        guard let router = appContainer?.sourceRouter else { return }
        isSearching = true
        errorMessage = nil
        do {
            let albums = try await router.search(src: selectedSrc, keyword: keyword)
            results = albums
        } catch let error as AntibotException {
            pendingKeyword = error.keyword.isEmpty ? keyword : error.keyword
            showAntibotSheet = true // 引导人工验证（不自动破解）
        } catch let error as PaidChapterException {
            errorMessage = "该章节为付费内容，已拦截"
        } catch {
            errorMessage = "搜索失败：\(error.localizedDescription)"
            print("Search error (\(selectedSrc)): \(error)")
        }
        isSearching = false
    }
}
