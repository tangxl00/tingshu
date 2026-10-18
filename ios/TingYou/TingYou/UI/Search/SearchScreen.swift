import SwiftUI

struct SearchScreen: View {
    @State private var keyword = ""
    @State private var results: [Album] = []
    @State private var isSearching = false

    var body: some View {
        List {
            ForEach(results) { album in
                AlbumRow(album: album)
            }
        }
        .listStyle(.plain)
        .searchable(text: $keyword)
        .onSubmit(of: .search) {
            Task { await search() }
        }
        .navigationTitle("搜索")
    }

    private func search() async {
        guard !keyword.isEmpty else { return }
        isSearching = true
        do {
            let client = APIClient()
            let repo = AlbumRepository(apiClient: client, modelContext: ModelContext(.init(schema: Schema([]))))
            let resp = try await repo.search(keyword: keyword, page: 1)
            results = resp.items
        } catch {
            print("Search error: \(error)")
        }
        isSearching = false
    }
}
