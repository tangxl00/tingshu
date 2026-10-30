import Foundation

/// build 22 · 对齐安卓 v1.3.3：搜索一次聚合「全部启用音源」的结果。
/// 安卓对应物：SearchViewModel.kt 的 `SEARCH_SOURCES.filter { it in enabled }` 并行聚合。
/// 搜索范围 = SourceEnabledStore 的启用集（「我的→音源管理」开关真正生效）；
/// 顺序 = SourceEnabledStore.searchSources 固定序（build 36 删听吧后 6 源）；
/// 逐源容错：单源失败收集源名如实透出、全源失败才视为整体失败
///（对齐安卓 anySuccess 语义）。
/// build 45 · 反馈 3：悦听（ytysxs）全链摘除——AntibotException 人工验证闭环
/// 与 antibotKeyword 回传字段一并删除（不再有反爬验证源）。
/// build 51 · P1-1（质检必修）：逐源增量回填 + 单源 3s 超时护栏。
/// 原实现等 `withTaskGroup` 全部源收齐才组装，而单源最坏耗时 =
/// APIClient 15s/20s × 最多 3 次 + 0.5s/1.0s 退避 ≈ 46.5s（易听书 live 探测再叠一层），
/// 结果「一个慢源拖住全部结果」：CI testG 33.1s→41.6s→55.4s 逐版恶化直至失败。
/// 现在：① 每个源最多 3s（超时按失败源透出，不再阻塞其余源上屏）；
/// ② 每源结果一到就按固定序回填并通过 onPartial 增量上屏（不破坏 fixed order）。
protocol SourceSearching {
    func search(src: String, keyword: String) async throws -> [Album]
}

extension SourceRouter: SourceSearching {}

/// 单源超时（build 51 · P1-1）。3s 覆盖真实弱网首屏；
/// 超时的源按「本次不可用」透出源名，不当成整体失败。
struct SourceSearchTimeoutError: Error, LocalizedError {
    let src: String
    var errorDescription: String? { "搜索超时（>3s）：\(SourceRegistry.displayName(src: src))" }
}

/// 聚合搜索结果（源名透出）。
struct AggregateSearchOutcome: Sendable {
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

    /// 已完成（返回结果或判失败）的源数（增量回填进度用）
    var settledSourceCount: Int { searchedSources.count - pendingSourceCount }
    /// 尚未返回的源数
    var pendingSourceCount: Int = 0
}

struct AggregateSearcher {
    let searcher: SourceSearching
    let enabledStore: SourceEnabledStore

    /// 单源超时护栏（build 51 · P1-1）。测试可注入更短值。
    static let perSourceTimeout: Duration = .seconds(3)

    /// 本轮参与聚合的启用源（固定顺序过滤启用集；导入不参与）。
    var enabledSources: [String] {
        enabledStore.enabledSearchSources()
    }

    /// 聚合搜索。
    /// - Parameters:
    ///   - keyword: 关键词
    ///   - timeout: 单源超时（默认 3s）
    ///   - onPartial: 增量回填回调（MainActor）：每返回一个源就回调一次当前已聚合的结果，
    ///     供 UI 先把快的源上屏；回调里的 albums 仍是固定序（未返回的源按空处理）。
    func search(keyword: String,
                timeout: Duration = AggregateSearcher.perSourceTimeout,
                onPartial: (@MainActor (AggregateSearchOutcome) -> Void)? = nil) async -> AggregateSearchOutcome {
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
                    // build 51 · P1-1：单源限时 3s——超时视为该源失败，
                    // 不再让一个慢源把整轮搜索拖到 46.5s。
                    let result = await Self.boundedSearch(
                        searcher: searcher, src: src, keyword: keyword, timeout: timeout)
                    return (idx, result)
                }
            }
            for await (idx, result) in group {
                results[idx] = result
                // build 51 · P1-1：增量回填——先到的源先上屏
                if let onPartial {
                    let partial = Self.snapshot(results: results, sources: sources)
                    await onPartial(partial)
                }
            }
        }
        return Self.snapshot(results: results, sources: sources)
    }

    /// 按固定序把已回填的结果组装成 outcome（未返回的源按 pending 计）
    private static func snapshot(results: [Result<[Album], Error>?],
                                 sources: [String]) -> AggregateSearchOutcome {
        var albums: [Album] = []
        var failed: [String] = []
        var pending = 0
        for (idx, result) in results.enumerated() {
            switch result {
            case .success(let items)?:
                albums.append(contentsOf: items)
            case .failure:
                failed.append(SourceRegistry.displayName(src: sources[idx]))
            case nil:
                pending += 1
            }
        }
        var outcome = AggregateSearchOutcome(
            albums: albums,
            failedSourceNames: failed,
            searchedSources: sources
        )
        outcome.pendingSourceCount = pending
        return outcome
    }

    /// 单源限时执行：结果先到即取，超过 timeout 直接判该源失败。
    /// 用 unstructured race（而不是内层 TaskGroup）——内层 group 退出会等待全部子任务，
    /// 底层请求若不响应取消就仍会挂在 scope 退出口，限时形同虚设。
    private static func boundedSearch(searcher: SourceSearching,
                                      src: String,
                                      keyword: String,
                                      timeout: Duration) async -> Result<[Album], Error> {
        let once = OneShotBox()
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<[Album], Error>, Never>) in
            Task {
                do {
                    let items = try await searcher.search(src: src, keyword: keyword)
                    if once.claim() { cont.resume(returning: .success(items)) }
                } catch {
                    if once.claim() { cont.resume(returning: .failure(error)) }
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if once.claim() { cont.resume(returning: .failure(SourceSearchTimeoutError(src: src))) }
            }
        }
    }

    /// 保证 continuation 只被 resume 一次（超时与结果两条路径竞争）
    private final class OneShotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
