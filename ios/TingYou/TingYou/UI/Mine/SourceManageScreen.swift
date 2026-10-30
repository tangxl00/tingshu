import SwiftUI

/// 音源管理（P1-3）：开关状态经 SourceEnabledStore 持久化到 UserDefaults（source_enabled_ 前缀）。
/// build 22 · 对齐安卓 v1.3.3：开关真正控制「哪些音源参与搜索聚合」
/// （搜索页/发现页搜索均读 SourceEnabledStore 启用集）；
/// 至少保留一个启用源（关闭最后一个搜索源时拒绝并提示，对齐安卓 toggleSource）；
/// 「导入」不参与搜索聚合，开关行保留并如实标注。
///
/// v1.4.2 · 音源连通性检测：对每个参与搜索的音源发起一次轻量真实请求，
/// 可用显示绿色延迟毫秒数、不可用标红「不可用」。
/// 各源并发、10 秒超时、失败不重试；瞬时状态不持久化，
/// 重新点「检测」重测；「导入」为本地源不参与检测，如实标注。
///
/// build 45 · 反馈 3：悦听有声书（ytysxs）全链摘除（用户点名删除）——
/// 安全验证区块（入口/状态/verify sheet/KeychainTokenStore 依赖）与
/// 音源行整体删除；存量书架 ytysxs 来源的书保留可读、播放时按
/// describePlaybackError 字符串兼容提示「源已下架」。
struct SourceManageScreen: View {
    @State private var model = SourceManageModel()
    @Environment(\.appContainer) private var appContainer
    /// v1.4.2：进入页面自动检测一次（手动「检测」可随时重测）
    @State private var didAutoProbe = false

    var body: some View {
        List {
            Section {
                ForEach(model.rows) { row in
                    Toggle(isOn: Binding(
                        get: { model.isEnabled(row.id) },
                        set: { model.setEnabled(row.id, $0) }
                    )) {
                        HStack(spacing: 6) {
                            Text(row.name)
                            if let note = row.note {
                                Text("（\(note)）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            probeBadge(row.id)
                        }
                    }
                }
            } header: {
                Text("选择搜索时使用的音源")
            } footer: {
                if model.lastToggleRejected {
                    Text("至少保留一个音源")
                } else {
                    Text("检测为瞬时状态，重新点右上角「检测」可重测")
                }
            }
        }
        .navigationTitle("音源管理")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("检测") {
                    startProbing()
                }
            }
        }
        .task {
            guard !didAutoProbe else { return }
            didAutoProbe = true
            startProbing()
        }
    }

    private func startProbing() {
        guard let container = appContainer else { return }
        Task { await model.probeAll(router: container.sourceRouter) }
    }

    /// v1.4.2：行内检测状态徽标——绿延迟 / 红「不可用」/ 检测中小菊花
    /// build 45 · 反馈 3：悦听摘除后不再有反爬验证源，「需验证」态一并删除。
    @ViewBuilder
    private func probeBadge(_ id: String) -> some View {
        switch model.probe(for: id) {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("检测中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .ok(let ms):
            Text("\(ms) ms")
                .font(.caption)
                .foregroundStyle(.green)
        case .unavailable:
            Text("不可用")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

@Observable
final class SourceManageModel {
    struct Row: Identifiable {
        let id: String
        let name: String
        /// build 22：不参与搜索聚合的源（导入）——UI 如实标注
        /// v1.4.2：本地导入源同样不参与连通性检测
        let note: String?
    }

    let store = SourceEnabledStore()
    let rows: [Row] = [
        Row(id: SourceRegistry.TINGYOU, name: "听友FM", note: nil),
        Row(id: SourceRegistry.BILI, name: "B站", note: nil),
        Row(id: SourceRegistry.YITINGSHU, name: "易听书", note: nil),
        Row(id: SourceRegistry.IMPORT, name: "导入", note: "不参与搜索与检测"),
    ]

    /// build 22：最后一次切换被「至少保留一个」保护拒绝（UI 短暂提示，对齐安卓 lastToggleRejected）
    private(set) var lastToggleRejected = false

    // MARK: - v1.4.2 连通性检测（瞬时状态，不持久化）

    /// 各源检测结果（未检测的源不在表内，probe(for:) 兜底 .idle）
    private(set) var probes: [String: SourceProbe] = [:]

    func probe(for id: String) -> SourceProbe {
        probes[id] ?? .idle
    }

    /// 并发检测全部参与搜索的音源（导入除外）——单源 10s 超时、失败不重试、不轰炸。
    /// @MainActor：probes 写入全部落主线程，行内状态随结果逐个刷新。
    @MainActor
    func probeAll(router: SourceRouter) async {
        let targets = rows.map(\.id).filter { $0 != SourceRegistry.IMPORT }
        for id in targets {
            probes[id] = .checking
        }
        await withTaskGroup(of: (String, SourceProbe).self) { group in
            for id in targets {
                group.addTask {
                    await (id, Self.probeOne(router: router, id: id))
                }
            }
            for await (id, result) in group {
                probes[id] = result
            }
        }
    }

    private enum ProbeOutcome {
        case ok
        case failed
    }

    /// 单源探测：各源最轻真实接口各发一次请求，与 10s 超时竞速（先到者胜，输者取消）。
    /// 接口选择原则：一次、轻量、能证明「可用」（成功解析出真实数据）而非只 ping 通——
    /// 听友FM rank 榜单 / B站 首个分类页（复用发现页分类路由）。
    /// build 45 · 反馈 3：悦听探测分支与 AntibotException 捕获删除。
    private static func probeOne(router: SourceRouter, id: String) async -> SourceProbe {
        let clock = ContinuousClock()
        let start = clock.now
        let outcome: ProbeOutcome = await withTaskGroup(of: ProbeOutcome.self) { group in
            group.addTask {
                do {
                    switch id {
                    case SourceRegistry.TINGYOU:
                        _ = try await router.discoverCategory(src: id, categoryId: "recommend", page: 1)
                    case SourceRegistry.BILI:
                        _ = try await router.discoverCategory(src: id, categoryId: "hot", page: 1)
                    case SourceRegistry.YITINGSHU:
                        _ = try await router.discoverCategory(src: id, categoryId: "1", page: 1)
                    default:
                        return .failed
                    }
                    return .ok
                } catch {
                    return .failed
                }
            }
            group.addTask {
                // 10s 超时：先到即判「不可用」，取消仍在跑的请求（不重试轰炸）
                try? await Task.sleep(for: .seconds(10))
                return .failed
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
        let elapsed = clock.now - start
        let ms = elapsedMs(elapsed)
        switch outcome {
        case .ok:
            return .ok(ms: ms)
        case .failed:
            return .unavailable
        }
    }

    private static func elapsedMs(_ d: Duration) -> Int {
        let comps = d.components
        // build 41 · P2：分母 10^12（attosecond→微秒）误标毫秒，延迟显示放大 1000 倍
        //（截图 375,625ms 实为 375.625ms）——修正为 10^15（attosecond→毫秒）。
        return Int(comps.seconds) * 1000 + Int(comps.attoseconds / 1_000_000_000_000_000)
    }

    private var enabledMap: [String: Bool] = [:]
    /// 拒绝提示自动消退的 Task（新一轮切换前取消旧的）
    private var clearRejectedTask: Task<Void, Never>?

    init() {
        for row in rows {
            enabledMap[row.id] = store.isEnabled(row.id)
        }
    }

    func isEnabled(_ id: String) -> Bool {
        enabledMap[id] ?? true
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        // build 22 · 对齐安卓 toggleSource：关闭最后一个启用的搜索源时拒绝（定向守卫）
        guard store.setEnabledGuarded(id, enabled) else {
            lastToggleRejected = true
            enabledMap[id] = store.isEnabled(id) // 同步回真实状态（Toggle 不停留 in-between）
            clearRejectedTask?.cancel()
            clearRejectedTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { lastToggleRejected = false }
            }
            return
        }
        lastToggleRejected = false
        enabledMap[id] = store.isEnabled(id)
    }
}

/// v1.4.2 · 音源连通性检测结果（瞬时状态，不持久化）
/// build 45 · 反馈 3：needsVerify 态随悦听源一并删除（不再有反爬验证源）。
enum SourceProbe: Equatable {
    /// 未检测
    case idle
    /// 检测中
    case checking
    /// 可用（延迟毫秒数：请求发起到成功响应）
    case ok(ms: Int)
    /// 不可用（请求失败或 10s 超时）
    case unavailable
}
