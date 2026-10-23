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
                        ShelfScreen(onOpenPlayer: {})
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
                        Text("1.4.0 (29)")
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
    @Environment(\.appContainer) private var container

    private var themeMode: Int {
        container?.themeStore.themeMode ?? ThemeStore.MODE_FOLLOW_SYSTEM
    }

    var body: some View {
        List {
            themeRow("浅色", mode: ThemeStore.MODE_LIGHT)
            themeRow("深色", mode: ThemeStore.MODE_DARK)
            themeRow("跟随系统", mode: ThemeStore.MODE_FOLLOW_SYSTEM)
        }
        .navigationTitle("外观模式")
    }

    /// 统一选择行：按压反馈（.pressable）+ 选中高亮底色，选中态与按压态可区分
    private func themeRow(_ title: String, mode: Int) -> some View {
        let selected = themeMode == mode
        return Button {
            container?.themeStore.setMode(mode)
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .listRowBackground(
            Group { if selected { Color.accentColor.opacity(0.12) } }
        )
    }
}

extension View {
    func checkmark(_ show: Bool) -> some View {
        HStack {
            self
            Spacer()
            if show { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
    }
}
