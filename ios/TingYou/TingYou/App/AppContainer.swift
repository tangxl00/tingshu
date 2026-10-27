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

        let ctx = modelContainer.mainContext
        albumRepository = AlbumRepository(apiClient: apiClient, modelContext: ctx)
        // build 45 · 反馈 3：悦听有声书（ytysxs）全链摘除——
        // ytysxsCookieStore / YtysxsAdapter 装配删除（KeychainTokenStore
        // 专用链随源一并删除，唯一消费方即悦听验证闭环）。
        let biliAdapter = BiliAdapter()
        let biliSearchApi = BiliSearchApi(adapter: biliAdapter)
        sourceRouter = SourceRouter(
            apiClient: apiClient,
            albumRepository: albumRepository,
            biliAdapter: biliAdapter,
            biliSearchApi: biliSearchApi)
        // P0-1：PlaybackManager 通过 AVAssetResourceLoaderDelegate 接管
        // tingyou-chapter:// 占位 URI，播放时实时向 PlaybackRepository 解析真实直链。
        playbackManager = PlaybackManager(playbackRepository: sourceRouter.playbackRepository)
        // Bug 2：播放历史落库出口接线（起播/切章/5s 节流/暂停 → HistoryModel upsert）
        playbackManager.historyRecorder = albumRepository
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
