import SwiftUI

struct SourceManageScreen: View {
    @State private var sources: [(id: String, name: String, enabled: Bool)] = [
        ("tingyou", "听友FM", true),
        ("ting15", "听十五", true),
        ("ting08", "听吧", true),
        ("ytysxs", "悦听有声书", true),
        ("mekui", "书音FM", true),
        ("import", "导入", true),
    ]

    var body: some View {
        List {
            ForEach($sources, id: \.id) { $src in
                Toggle(src.name, isOn: $src.enabled)
            }
        }
        .navigationTitle("音源管理")
    }
}
