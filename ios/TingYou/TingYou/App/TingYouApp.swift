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
        }
        .modelContainer(container.modelContainer)
    }
}
