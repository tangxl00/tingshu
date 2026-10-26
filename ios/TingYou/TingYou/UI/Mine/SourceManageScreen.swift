import SwiftUI

/// 音源管理（P1-3）：开关状态经 SourceEnabledStore 持久化到 UserDefaults（source_enabled_ 前缀）。
/// build 22 · 对齐安卓 v1.3.3：开关真正控制「哪些音源参与搜索聚合」
/// （搜索页/发现页搜索均读 SourceEnabledStore 启用集）；
/// 至少保留一个启用源（关闭最后一个搜索源时拒绝并提示，对齐安卓 toggleSource）；
/// 「导入」不参与搜索聚合，开关行保留并如实标注。
///
/// v1.4.2 · 悦听安全验证迁移：验证流程自发现页弹窗迁入本页——
/// 悦听有声书提供独立「安全验证」入口（拉起 YtysxsVerifySheet），
/// 发现页触发 AntibotException 时不再弹窗，只显示引导文案指向本页。
///
/// v1.4.2 · 音源连通性检测：对每个参与搜索的音源发起一次轻量真实请求
/// （听友FM 榜单 / 听十五·B站·59听书 各自最轻分类页、悦听·书音一次小搜索），
/// 可用显示绿色延迟毫秒数、不可用标红「不可用」；悦听命中反爬视为「站点可达但需验证」
/// （延迟 + 需验证标注）。各源并发、10 秒超时、失败不重试；瞬时状态不持久化，
/// 重新点「检测」重测；「导入」为本地源不参与检测，如实标注。
struct SourceManageScreen: View {
    @State private var model = SourceManageModel()
    @Environment(\.appContainer) private var appContainer
    /// v1.4.2：悦听安全验证 sheet（入口见「安全验证」区块）
    @State private var showVerifySheet = false
    /// v1.4.2：悦听验证状态（Keychain 有效 token 判定；sheet 关闭后刷新）
    @State private var ytysxsVerified = false
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

            // v1.4.2 · 悦听安全验证迁移：独立入口（发现页拦截不再弹窗，指向此处）
            Section {
                Button {
                    ytysxsVerified = verifyStore().hasValidToken()
                    showVerifySheet = true
                } label: {
                    HStack {
                        Text("悦听有声书 · 安全验证")
                        Spacer()
                        Text(ytysxsVerified ? "已验证" : "未验证")
                            .font(.caption)
                            .foregroundStyle(ytysxsVerified ? .green : .secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(Color(.systemGray3))
                    }
                }
                .foregroundStyle(.primary)
            } header: {
                Text("安全验证")
            } footer: {
                Text("悦听有反爬验证门，验证通过后 24 小时内搜索/详情自动放行；搜索命中拦截时不再弹窗，请在此完成验证后重试。")
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
            ytysxsVerified = verifyStore().hasValidToken()
            guard !didAutoProbe else { return }
            didAutoProbe = true
            startProbing()
        }
        .sheet(isPresented: $showVerifySheet) {
            YtysxsVerifySheet(
                keyword: "",
                cookieStore: verifyStore()) { _ in
                showVerifySheet = false
                ytysxsVerified = verifyStore().hasValidToken()
            }
        }
    }

    /// v1.4.2：悦听 cookie 存储——容器不可用（预览态）时退回独立实例（只读验证状态，不落验证成果）
    private func verifyStore() -> KeychainTokenStore {
        appContainer?.ytysxsCookieStore ?? KeychainTokenStore()
    }

    private func startProbing() {
        guard let container = appContainer else { return }
        Task { await model.probeAll(router: container.sourceRouter) }
    }

    /// v1.4.2：行内检测状态徽标——绿延迟 / 橙「需验证」/ 红「不可用」/ 检测中小菊花
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
        case .needsVerify(let ms):
            // build 36 · 反馈 5：「需验证」与实际 token 有效性联动——完成人机验证
            // （token 有效）后不再显示死文案；仅 token 无效时如实提示。
            // 验证 sheet 关闭回调刷新 ytysxsVerified 触发重渲染，此处实时读 token。
            // 仅悦听有验证 token 闭环；59听书（vdcode 请求级验证码）无 token，恒提示。
            if id == SourceRegistry.YTYXSX, verifyStore().hasValidToken() {
                Text("\(ms) ms")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("\(ms) ms · 需验证")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
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
        Row(id: SourceRegistry.TING15, name: "听十五", note: nil),
        Row(id: SourceRegistry.YTYXSX, name: "悦听有声书", note: nil),
        Row(id: SourceRegistry.MEKUI, name: "书音FM", note: nil),
        Row(id: SourceRegistry.BILI, name: "B站", note: nil),
        Row(id: SourceRegistry.TING59, name: "59听书网", note: nil),
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
        case antibot
        case failed
    }

    /// 单源探测：各源最轻真实接口各发一次请求，与 10s 超时竞速（先到者胜，输者取消）。
    /// 接口选择原则：一次、轻量、能证明「可用」（成功解析出真实数据）而非只 ping 通——
    /// 听友FM rank 榜单 / 听十五·B站·59听书 各自首个分类页（复用发现页分类路由）/
    /// 悦听·书音一次小搜索（无更轻的既有探测路径）。
    private static func probeOne(router: SourceRouter, id: String) async -> SourceProbe {
        let clock = ContinuousClock()
        let start = clock.now
        let outcome: ProbeOutcome = await withTaskGroup(of: ProbeOutcome.self) { group in
            group.addTask {
                do {
                    switch id {
                    case SourceRegistry.TINGYOU:
                        _ = try await router.discoverCategory(src: id, categoryId: "recommend", page: 1)
                    case SourceRegistry.TING15:
                        _ = try await router.discoverCategory(src: id, categoryId: "wuxiaxuanhuan", page: 1)
                    case SourceRegistry.YTYXSX:
                        _ = try await router.search(src: id, keyword: "三体")
                    case SourceRegistry.MEKUI:
                        _ = try await router.search(src: id, keyword: "三体")
                    case SourceRegistry.BILI:
                        _ = try await router.discoverCategory(src: id, categoryId: "hot", page: 1)
                    case SourceRegistry.TING59:
                        _ = try await router.discoverCategory(src: id, categoryId: "xuanhuan", page: 1)
                    default:
                        return .failed
                    }
                    return .ok
                } catch is AntibotException {
                    return .antibot
                } catch is Ting59AntibotException {
                    // build 36 · 反馈 1：59听书站点级验证码页（vdcode）——站点可达但被
                    // 安全验证拦截，如实标「需验证」（与悦听同徽标，无 token 闭环）
                    return .antibot
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
        case .antibot:
            // 悦听反爬拦截：站点已应答（可达），只是需要安全验证——如实标「需验证」
            return .needsVerify(ms: ms)
        case .failed:
            return .unavailable
        }
    }

    private static func elapsedMs(_ d: Duration) -> Int {
        let comps = d.components
        return Int(comps.seconds) * 1000 + Int(comps.attoseconds / 1_000_000_000_000)
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
enum SourceProbe: Equatable {
    /// 未检测
    case idle
    /// 检测中
    case checking
    /// 可用（延迟毫秒数：请求发起到成功响应）
    case ok(ms: Int)
    /// 站点可达但命中反爬验证门（悦听未验证）——延迟照实显示，需安全验证
    case needsVerify(ms: Int)
    /// 不可用（请求失败或 10s 超时）
    case unavailable
}
