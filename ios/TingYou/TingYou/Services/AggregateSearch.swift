import Foundation

/// build 22 · 对齐安卓 v1.3.3：搜索一次聚合「全部启用音源」的结果。
/// 安卓对应物：SearchViewModel.kt 的 `SEARCH_SOURCES.filter { it in enabled }` 并行聚合。
/// 搜索范围 = SourceEnabledStore 的启用集（「我的→音源管理」开关真正生效）；
/// 顺序 = SourceEnabledStore.searchSources 固定序（build 36 删听吧后 6 源）；
/// 逐源容错：单源失败收集源名如实透出、全源失败才视为整体失败
///（对齐安卓 anySuccess 语义）。
/// build 45 · 反馈 3：悦听（ytysxs）全链摘除——AntibotException 人工验证闭环
/// 与 antibotKeyword 回传字段一并删除（不再有反爬验证源）。
protocol SourceSearching {
    func search(src: String, keyword: String) async throws -> [Album]
}

extension SourceRouter: SourceSearching {}

/// 聚合搜索结果（源名透出）。
struct AggregateSearchOutcome {
    /// 按固定音源顺序拼接的聚合结果
    let albums: [Album]
    /// 本次搜索失败（不可用）的源显示名，如实透出不静默
    let failedSourceNames: [String]
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
        let sources = enabledSources
        // build 24（P2-2 · 性能）：从固定序串行改为 withTaskGroup 并行请求全部启用源，
        // 弱网总耗时 ≈ 最慢单源而非逐源求和。对外行为不变：
        // - 结果仍按 searchSources 固定序拼接（回填数组按启动序遍历组装）
        // - 单源失败收名、allFailed 语义与串行版一致
        let searcher = self.searcher
        var results: [Result<[Album], Error>?] = Array(repeating: nil, count: sources.count)
        await withTaskGroup(of: (Int, Result<[Album], Error>).self) { group in
            for (idx, src) in sources.enumerated() {
                group.addTask {
                    do {
                        return (idx, .success(try await searcher.search(src: src, keyword: keyword)))
                    } catch {
                        return (idx, .failure(error))
                    }
                }
            }
            for await (idx, result) in group {
                results[idx] = result
            }
        }
        var albums: [Album] = []
        var failed: [String] = []
        for (idx, result) in results.enumerated() {
            switch result {
            case .success(let items)?:
                albums.append(contentsOf: items)
            case .failure:
                failed.append(SourceRegistry.displayName(src: sources[idx]))
            case nil:
                break // 不发生：group await 全部回填后才继续
            }
        }
        return AggregateSearchOutcome(
            albums: albums,
            failedSourceNames: failed,
            searchedSources: sources
        )
    }
}
