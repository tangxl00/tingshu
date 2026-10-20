import SwiftUI
import SwiftData

@main
struct TingYouApp: App {
    let container: AppContainer

    init() {
        container = AppContainer()
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
