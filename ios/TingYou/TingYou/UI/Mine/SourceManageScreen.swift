import SwiftUI

/// 音源管理（P1-3）：开关状态经 SourceEnabledStore 持久化到 UserDefaults（source_enabled_ 前缀）。
/// build 22 · 对齐安卓 v1.3.3：开关真正控制「哪些音源参与搜索聚合」
/// （搜索页/发现页搜索均读 SourceEnabledStore 启用集）；
/// 至少保留一个启用源（关闭最后一个搜索源时拒绝并提示，对齐安卓 toggleSource）；
/// 「导入」不参与搜索聚合，开关行保留并如实标注。
struct SourceManageScreen: View {
    @State private var model = SourceManageModel()

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
                        }
                    }
                }
            } header: {
                Text("选择搜索时使用的音源")
            } footer: {
                if model.lastToggleRejected {
                    Text("至少保留一个音源")
                }
            }
        }
        .navigationTitle("音源管理")
    }
}

@Observable
final class SourceManageModel {
    struct Row: Identifiable {
        let id: String
        let name: String
        /// build 22：不参与搜索聚合的源（导入）——UI 如实标注
        let note: String?
    }

    let store = SourceEnabledStore()
    let rows: [Row] = [
        Row(id: SourceRegistry.TINGYOU, name: "听友FM", note: nil),
        Row(id: SourceRegistry.TING15, name: "听十五", note: nil),
        Row(id: SourceRegistry.TING08, name: "听吧", note: nil),
        Row(id: SourceRegistry.YTYXSX, name: "悦听有声书", note: nil),
        Row(id: SourceRegistry.MEKUI, name: "书音FM", note: nil),
        Row(id: SourceRegistry.IMPORT, name: "导入", note: "不参与搜索"),
    ]

    /// build 22：最后一次切换被「至少保留一个」保护拒绝（UI 短暂提示，对齐安卓 lastToggleRejected）
    private(set) var lastToggleRejected = false

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
