import Foundation

/// build 22 · 对齐安卓 v1.3.3：搜索一次聚合「全部启用音源」的结果。
/// 安卓对应物：SearchViewModel.kt 的 `SEARCH_SOURCES.filter { it in enabled }` 并行聚合。
/// 搜索范围 = SourceEnabledStore 的启用集（「我的→音源管理」开关真正生效）；
/// 顺序 = SourceEnabledStore.searchSources 固定序（tingyou→ting15→ting08→ytysxs→mekui）；
/// 逐源容错：单源失败收集源名如实透出、悦听 AntibotException 走人工验证闭环、
/// 全源失败才视为整体失败（对齐安卓 anySuccess 语义）。
protocol SourceSearching {
    func search(src: String, keyword: String) async throws -> [Album]
}

extension SourceRouter: SourceSearching {}

/// 聚合搜索结果（源名透出 + 反爬关键词回传）。
struct AggregateSearchOutcome {
    /// 按固定音源顺序拼接的聚合结果
    let albums: [Album]
    /// 本次搜索失败（不可用）的源显示名，如实透出不静默
    let failedSourceNames: [String]
    /// 悦听命中反爬拦截时回传关键词（弹 YtysxsVerifySheet 用）
    let antibotKeyword: String?
    /// 实际参与了搜索的源（启用集）
    let searchedSources: [String]

    /// 所有参与的源都失败了（对齐安卓 !anySuccess：此时才报整体错误）
    var allFailed: Bool {
        !searchedSources.isEmpty && failedSourceNames.count == searchedSources.count
    }
}

struct AggregateSearcher {
    let searcher: SourceSearching
    let enabledStore: SourceEnabledStore

    /// 本轮参与聚合的启用源（固定顺序过滤启用集；导入不参与）。
    var enabledSources: [String] {
        enabledStore.enabledSearchSources()
    }

    func search(keyword: String) async -> AggregateSearchOutcome {
        var albums: [Album] = []
        var failed: [String] = []
        var antibotKeyword: String?
        let sources = enabledSources
        for src in sources {
            do {
                let items = try await searcher.search(src: src, keyword: keyword)
                albums.append(contentsOf: items)
            } catch let error as AntibotException {
                antibotKeyword = error.keyword.isEmpty ? keyword : error.keyword
            } catch {
                failed.append(SourceRegistry.displayName(src: src))
            }
        }
        return AggregateSearchOutcome(
            albums: albums,
            failedSourceNames: failed,
            antibotKeyword: antibotKeyword,
            searchedSources: sources
        )
    }
}
