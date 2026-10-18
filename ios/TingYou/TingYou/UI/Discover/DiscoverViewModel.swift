import Foundation
import SwiftData

@Observable
final class DiscoverViewModel {
    var albums: [Album] = []
    var hasMore = false
    private var currentPage = 1
    private var currentSection = "recommend"
    private var isLoading = false

    func loadRank(section: String) async {
        guard !isLoading else { return }
        isLoading = true
        currentSection = section
        currentPage = 1
        do {
            let client = APIClient()
            let repo = AlbumRepository(apiClient: client, modelContext: ModelContext(.init(schema: Schema([]))))
            let result = try await repo.rank(section: section, page: 1)
            albums = result.items
            hasMore = result.hasMore
        } catch {
            print("Discover load error: \(error)")
        }
        isLoading = false
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        currentPage += 1
        do {
            let client = APIClient()
            let repo = AlbumRepository(apiClient: client, modelContext: ModelContext(.init(schema: Schema([]))))
            let result = try await repo.rank(section: currentSection, page: currentPage)
            albums.append(contentsOf: result.items)
            hasMore = result.hasMore
        } catch {
            print("Discover loadMore error: \(error)")
        }
        isLoading = false
    }
}
