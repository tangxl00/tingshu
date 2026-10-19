import SwiftUI

/// 音源管理（P1-3）：开关状态经 SourceEnabledStore 持久化到 UserDefaults（source_enabled_ 前缀），
/// 重启后保持；不再是静态占位列表。
struct SourceManageScreen: View {
    @State private var model = SourceManageModel()

    var body: some View {
        List {
            ForEach(model.rows) { row in
                Toggle(row.name, isOn: Binding(
                    get: { model.isEnabled(row.id) },
                    set: { model.setEnabled(row.id, $0) }
                ))
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
    }

    let store = SourceEnabledStore()
    let rows: [Row] = [
        Row(id: SourceRegistry.TINGYOU, name: "听友FM"),
        Row(id: SourceRegistry.TING15, name: "听十五"),
        Row(id: SourceRegistry.TING08, name: "听吧"),
        Row(id: SourceRegistry.YTYXSX, name: "悦听有声书"),
        Row(id: SourceRegistry.MEKUI, name: "书音FM"),
        Row(id: SourceRegistry.IMPORT, name: "导入"),
    ]

    private var enabledMap: [String: Bool] = [:]

    init() {
        for row in rows {
            enabledMap[row.id] = store.isEnabled(row.id)
        }
    }

    func isEnabled(_ id: String) -> Bool {
        enabledMap[id] ?? true
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        enabledMap[id] = enabled
        store.setEnabled(id, enabled) // 真持久化（UserDefaults source_enabled_ 前缀）
    }
}
