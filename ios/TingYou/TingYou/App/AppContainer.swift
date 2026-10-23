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
    /// 悦听反爬 be_captcha_token 的 Keychain 存储（P0-4）：
    /// SearchScreen 验证页与 SourceRouter 内的 YtysxsAdapter 共享同一实例，
    /// 人工验证完成后适配器立即带上新 token 重试。
    let ytysxsCookieStore: KeychainTokenStore

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
        ytysxsCookieStore = KeychainTokenStore()
        let biliAdapter = BiliAdapter()
        let biliSearchApi = BiliSearchApi(adapter: biliAdapter)
        let ting59Adapter = Ting59Adapter()
        sourceRouter = SourceRouter(
            apiClient: apiClient,
            albumRepository: albumRepository,
            ytysxsAdapter: YtysxsAdapter(apiClient: apiClient, cookieStore: ytysxsCookieStore),
            biliAdapter: biliAdapter,
            biliSearchApi: biliSearchApi,
            ting59Adapter: ting59Adapter)
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
