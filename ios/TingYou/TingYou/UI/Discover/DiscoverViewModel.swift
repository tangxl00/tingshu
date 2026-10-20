import Foundation
import SwiftData

/// 发现页 ViewModel（P1 修复：APIClient 经 attach 注入后全程复用单例，
/// 不再在每次 loadRank / loadMore 中新建 APIClient 与 AlbumRepository；
/// 增强 5.1：分区第 1 页数据本地缓存——启动先渲染上次缓存，后台静默刷新替换）。
@Observable
final class DiscoverViewModel {
    var albums: [Album] = []
    var hasMore = false
    private var currentPage = 1
    private var currentSection = "recommend"
    private var isLoading = false
    private var repo: (any DiscoverDataLoading)?
    private var cache: (any DiscoverCacheStore)?

    /// 幂等注入共享客户端（AppContainer.apiClient）与本地缓存。
    /// 默认使用磁盘缓存；单测可注入假实现验证「优先读缓存」路径。
    func attach(apiClient: APIClient, cache: (any DiscoverCacheStore)? = DiskDiscoverCache()) {
        attach(loader: AlbumRepository(apiClient: apiClient), cache: cache)
    }

    /// 测试入口：直接注入假数据源（TingYouTests/DiscoverCacheTests）。
    func attach(loader: any DiscoverDataLoading, cache: (any DiscoverCacheStore)? = DiskDiscoverCache()) {
        guard repo == nil else { return }
        repo = loader
        self.cache = cache
    }

    func loadRank(section: String) async {
        guard let repo = repo, !isLoading else { return }
        isLoading = true
        currentSection = section
        currentPage = 1

        // 增强 5.1：列表为空时先渲染上次缓存（打开秒显），失败也保留缓存内容
        if albums.isEmpty, let cached = cache?.loadSection(section), !cached.isEmpty {
            albums = cached
        }

        do {
            let result = try await repo.loadRank(section: section, page: 1)
            // 等待期间分区若已变化则丢弃过期结果（防御性保护）
            guard currentSection == section else {
                isLoading = false
                return
            }
            albums = result.items
            hasMore = result.hasMore
            if !result.items.isEmpty {
                try? cache?.saveSection(section, albums: result.items)
            }
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
            let result = try await repo.loadRank(section: currentSection, page: currentPage)
            albums.append(contentsOf: result.items)
            hasMore = result.hasMore
        } catch {
            print("Discover loadMore error: \(error)")
        }
        isLoading = false
    }
}
