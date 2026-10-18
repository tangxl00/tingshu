import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class AppContainer {
    let modelContainer: ModelContainer
    let apiClient: APIClient
    let playbackManager: PlaybackManager
    let albumRepository: AlbumRepository
    let sourceRouter: SourceRouter
    let importService: ImportService
    let themeStore: ThemeStore
    let listeningTimeStore: ListeningTimeStore
    let skipSettingsStore: SkipSettingsStore
    let sourceEnabledStore: SourceEnabledStore
    let shelfLayoutStore: ShelfLayoutStore

    init() {
        let schema = Schema([
            FavoriteModel.self,
            HistoryModel.self,
            ImportedBookModel.self,
            ImportedChapterModel.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        modelContainer = try! ModelContainer(for: schema, configurations: [config])

        apiClient = APIClient()
        playbackManager = PlaybackManager()

        let ctx = modelContainer.mainContext
        albumRepository = AlbumRepository(apiClient: apiClient, modelContext: ctx)
        sourceRouter = SourceRouter(apiClient: apiClient)
        importService = ImportService(modelContext: ctx)

        themeStore = ThemeStore()
        listeningTimeStore = ListeningTimeStore()
        skipSettingsStore = SkipSettingsStore()
        sourceEnabledStore = SourceEnabledStore()
        shelfLayoutStore = ShelfLayoutStore()
    }
}

extension EnvironmentValues {
    @Entry var appContainer: AppContainer? = nil
}

extension View {
    func environment(_ container: AppContainer) -> some View {
        self.environment(\.appContainer, container)
    }
}
