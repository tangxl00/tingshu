import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab = 1
    @Environment(\.appContainer) private var container

    var body: some View {
        TabView(selection: $selectedTab) {
            ShelfScreen()
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(0)
            DiscoverScreen()
                .tabItem { Label("发现", systemImage: "compass") }
                .tag(1)
            MineScreen()
                .tabItem { Label("我的", systemImage: "person") }
                .tag(2)
        }
    }
}
