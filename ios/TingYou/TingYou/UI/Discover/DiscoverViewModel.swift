import Foundation
import SwiftData

/// 发现页数据出口：tingyou rank API 与多源分类数据统一抽象。
/// build 21 · 反馈 4/6：发现页数据跟随所选音源切换，分类按原始音源结构拉取。
protocol DiscoverDataLoading: Sendable {
    func loadRank(section: String, page: Int) async throws -> PagedResult<Album>
    func discoverCategory(src: String, categoryId: String, page: Int) async throws -> (albums: [Album], hasMore: Bool)
}

/// AlbumRepository（tingyou rank）+ SourceRouter（分类路由）组合实现。
/// router 为 nil 时仅 tingyou 榜单可用（单测注入假 router 覆盖多源路径）。
struct CombinedDiscoverLoader: DiscoverDataLoading {
    let repo: AlbumRepository
    let router: SourceRouter?

    func loadRank(section: String, page: Int) async throws -> PagedResult<Album> {
        try await repo.rank(section: section, page: page)
    }

    func discoverCategory(src: String, categoryId: String, page: Int) async throws -> (albums: [Album], hasMore: Bool) {
        guard let router else { throw URLError(.unsupportedURL) }
        return try await router.discoverCategory(src: src, categoryId: categoryId, page: page)
    }
}

/// 发现页 ViewModel（P1 修复：APIClient 经 attach 注入后全程复用单例，
/// 不再在每次 loadRank / loadMore 中新建 APIClient 与 AlbumRepository；
/// 增强 5.1：分区第 1 页数据本地缓存——启动先渲染上次缓存，后台静默刷新替换；
/// build 21 · 反馈 4/6：加载目标扩展为「音源 + 分类」二维，按源路由数据出口）。
@Observable
final class DiscoverViewModel {
    var albums: [Album] = []
    var hasMore = false
    /// 最近一次加载是否失败（UI 显示错误与重试）
    var loadError: String?
    /// build 24（存量 P2）：加载更多失败的用户可见反馈——轻量提示 + 重试入口，
    /// 不弹窗打断；成功后自动清除。与 loadError 分离：loadMore 失败不该清空已加载列表。
    var loadMoreFailed = false
    private var currentPage = 1
    private var currentCacheKey = "tingyou|recommend"
    private var currentTarget: LoadTarget = .tingyouRank(section: "recommend")
    private var isLoading = false
    private var repo: (any DiscoverDataLoading)?
    private var cache: (any DiscoverCacheStore)?

    /// 加载目标（build 21）：tingyou 榜单 section 或某源某分类。
    enum LoadTarget: Equatable {
        case tingyouRank(section: String)
        case category(src: String, categoryId: String)
    }

    /// 幂等注入共享客户端（AppContainer.apiClient）与本地缓存。
    /// 默认使用磁盘缓存（build 24：启动一次性清理多源时代孤儿键）；
    /// v1.4.1：合法键前缀扩至 bili| / ting59|（浏览区新增两源的「src|cat」分区键，
    /// 否则每次 attach 会把上一会话写入的这两源缓存当孤儿清掉）；
    /// 单测可注入假实现验证「优先读缓存」路径。
    func attach(apiClient: APIClient, sourceRouter: SourceRouter? = nil, cache: (any DiscoverCacheStore)? = DiskDiscoverCache(validKeyPrefixes: ["tingyou|", "bili|"])) {
        attach(loader: CombinedDiscoverLoader(
            repo: AlbumRepository(apiClient: apiClient), router: sourceRouter), cache: cache)
    }

    /// 测试入口：直接注入假数据源（TingYouTests/DiscoverCacheTests）。
    func attach(loader: any DiscoverDataLoading, cache: (any DiscoverCacheStore)? = DiskDiscoverCache()) {
        guard repo == nil else { return }
        repo = loader
        self.cache = cache
    }

    /// 缓存键：按「音源|分类」分区（旧版只有 section 一个维度， tingyou 沿用旧键兼容历史缓存）。
    private static func cacheKey(for target: LoadTarget) -> String {
        switch target {
        case .tingyouRank(let section): return "tingyou|\(section)"
        case .category(let src, let cat): return "\(src)|\(cat)"
        }
    }

    /// 统一加载入口（第 1 页）。源不支持（ mekui/ytysxs 抛 unsupportedURL）时置 loadError。
    /// build 24：整页重载时同步清除加载更多的失败态。
    func load(target: LoadTarget) async {
        guard let repo = repo, !isLoading else { return }
        isLoading = true
        currentTarget = target
        currentCacheKey = Self.cacheKey(for: target)
        currentPage = 1
        loadError = nil
        loadMoreFailed = false

        // 增强 5.1：列表为空时先渲染上次缓存（打开秒显），失败也保留缓存内容
        if albums.isEmpty, let cached = cache?.loadSection(currentCacheKey), !cached.isEmpty {
            albums = cached
        }

        do {
            let result = try await fetch(page: 1)
            // 等待期间目标若已变化则丢弃过期结果（防御性保护）
            guard currentTarget == target else {
                isLoading = false
                return
            }
            albums = result.items
            hasMore = result.hasMore
            if !result.items.isEmpty {
                try? cache?.saveSection(currentCacheKey, albums: result.items)
            }
        } catch {
            // build 21 · 反馈 4：不支持的源 / 加载失败如实上报，不静默显示空列表
            loadError = Self.describe(error)
            print("Discover load error: \(error)")
        }
        isLoading = false
    }

    /// 兼容入口：tingyou 榜单（旧调用方 DiscoverScreen.task 之外的书架等处）。
    func loadRank(section: String) async {
        await load(target: .tingyouRank(section: section))
    }

    func loadMore() async {
        guard let repo = repo, !isLoading, hasMore, loadError == nil else { return }
        isLoading = true
        currentPage += 1
        do {
            let result = try await fetch(page: currentPage)
            albums.append(contentsOf: result.items)
            hasMore = result.hasMore
            loadMoreFailed = false
        } catch {
            currentPage -= 1 // 失败回退页码，允许重试同一页
            // build 24（存量 P2）：失败置轻量反馈态（UI 尾部显示提示 + 重试入口），
            // 不清空已加载列表、不弹窗打断
            loadMoreFailed = true
            print("Discover loadMore error: \(error)")
        }
        isLoading = false
    }

    private func fetch(page: Int) async throws -> PagedResult<Album> {
        switch currentTarget {
        case .tingyouRank(let section):
            return try await repo!.loadRank(section: section, page: page)
        case .category(let src, let categoryId):
            let r = try await repo!.discoverCategory(src: src, categoryId: categoryId, page: page)
            return PagedResult(items: r.albums, hasMore: r.hasMore)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .unsupportedURL {
            return "该源暂不支持发现页"
        }
        // build 44 · 反馈 5（听友FM TLS）：实测该音源证书链有效（Google Trust Services WE1，
        // 在本地 27 锚点集合内且锚点为 additive 模式），失败为外部间歇性 TLS 握手问题，
        // 客户端无法根治——把原始「A TLS error caused the secure connection to fail」
        // 映射成人话 + 规避建议（换音源），避免用户误以为 App 故障。
        if let urlError = error as? URLError, urlError.code == .secureConnectionFailed {
            return "安全连接失败：该音源服务器暂时无法建立加密连接，请稍后重试或切换其他音源"
        }
        return "加载失败：\(error.localizedDescription)"
    }
}
