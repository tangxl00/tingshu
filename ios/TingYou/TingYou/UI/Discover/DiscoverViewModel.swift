import Foundation
import SwiftData

/// 发现页 ViewModel（P1 修复：APIClient 经 attach 注入后全程复用单例，
/// 不再在每次 loadRank / loadMore 中新建 APIClient 与 AlbumRepository）。
@Observable
final class DiscoverViewModel {
    var albums: [Album] = []
    var hasMore = false
    private var currentPage = 1
    private var currentSection = "recommend"
    private var isLoading = false
    private var repo: AlbumRepository?

    /// 幂等注入共享客户端（AppContainer.apiClient）；未注入前不发起请求。
    func attach(apiClient: APIClient) {
        guard repo == nil else { return }
        repo = AlbumRepository(apiClient: apiClient,
                               modelContext: ModelContext(.init(schema: Schema([]))))
    }

    func loadRank(section: String) async {
        guard let repo = repo, !isLoading else { return }
        isLoading = true
        currentSection = section
        currentPage = 1
        do {
            let result = try await repo.rank(section: section, page: 1)
            albums = result.items
            hasMore = result.hasMore
        } catch {
            print("Discover load error: \(error)")
        }
        isLoading = false
    }

    func loadMore() async {
        guard let repo = repo, !isLoading, hasMore else { return }
        isLoading = true
        currentPage += 1
        do {
            let result = try await repo.rank(section: currentSection, page: currentPage)
            albums.append(contentsOf: result.items)
            hasMore = result.hasMore
        } catch {
            print("Discover loadMore error: \(error)")
        }
        isLoading = false
    }
}
