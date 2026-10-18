import SwiftUI

struct MineScreen: View {
    @Environment(\.appContainer) private var container
    @State private var showSourceManage = false

    var body: some View {
        NavigationStack {
            List {
                Section("听书数据") {
                    HStack {
                        Label("总时长", systemImage: "headphones")
                        Spacer()
                        Text(formatTime(container?.listeningTimeStore.totalMs ?? 0))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("今日时长", systemImage: "clock")
                        Spacer()
                        Text(formatTime(container?.listeningTimeStore.todayMs ?? 0))
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink("我的书架") {
                        ShelfScreen()
                    }
                }

                Section("外观") {
                    NavigationLink("外观模式") {
                        ThemePickerScreen()
                    }
                }

                Section("音源") {
                    NavigationLink("音源管理") {
                        SourceManageScreen()
                    }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.3.3 (16)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("我的")
        }
    }

    func formatTime(_ ms: Int64) -> String {
        let sec = ms / 1000
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 { return "\(h)小时\(m)分" }
        return "\(m)分钟"
    }
}

struct ThemePickerScreen: View {
    @AppStorage("theme_mode") private var themeMode: Int = 2

    var body: some View {
        List {
            Button("浅色") { themeMode = 0 }
                .checkmark(themeMode == 0)
            Button("深色") { themeMode = 1 }
                .checkmark(themeMode == 1)
            Button("跟随系统") { themeMode = 2 }
                .checkmark(themeMode == 2)
        }
        .navigationTitle("外观模式")
    }
}

extension View {
    func checkmark(_ show: Bool) -> some View {
        HStack {
            self
            Spacer()
            if show { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }
}
