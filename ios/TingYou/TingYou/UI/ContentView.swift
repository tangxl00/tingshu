import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab = 1
    @State private var showPlayer = false
    @Environment(\.appContainer) private var container

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                ShelfScreen(
                    onOpenPlayer: { showPlayer = true }
                )
                .tabItem {
                    Image(systemName: "books.vertical")
                    Text("书架")
                }
                .tag(0)

                DiscoverScreen(
                    onOpenAlbum: { _ in },
                    onOpenPlayer: { showPlayer = true }
                )
                .tabItem {
                    Image(systemName: "safari")
                    Text("发现")
                }
                .tag(1)

                MineScreen()
                .tabItem {
                    Image(systemName: "person.crop.circle")
                    Text("我的")
                }
                .tag(2)
            }

            // Mini Player Bar overlay above Tab Bar
            VStack {
                Spacer()
                MiniPlayerBar(onTap: {
                    showPlayer = true
                })
                .padding(.bottom, 49) // Tab bar height
            }
            .ignoresSafeArea(.keyboard)
        }
        .sheet(isPresented: $showPlayer) {
            PlayerScreen()
        }
    }
}
