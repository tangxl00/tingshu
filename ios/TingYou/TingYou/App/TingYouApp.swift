import SwiftUI
import SwiftData

@main
struct TingYouApp: App {
    let container: AppContainer

    init() {
        container = AppContainer()
        // build 45 · 反馈 4：全局「点搜索框以外任何地方」收起键盘——window 级
        // UIKit recognizer（cancelsTouchesInView=false 不吞事件，List 行导航
        // 照常激活），替代 b43/b44 的五处局部手势挂载。
        GlobalKeyboardDismiss.installOnce()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(container)
                // Bug 3 修复：外观模式此前只存不用（全工程无 .preferredColorScheme）。
                // 读取 @Observable ThemeStore.themeMode → 切换即时生效（无需重启）。
                .preferredColorScheme(
                    ThemeStore.colorScheme(for: container.themeStore.themeMode)
                )
        }
        .modelContainer(container.modelContainer)
    }
}
