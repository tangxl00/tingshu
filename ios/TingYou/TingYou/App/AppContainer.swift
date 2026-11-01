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
    /// build 50 · 云同步（邮箱验证码登录 + 收藏/进度云端同步 + 断网补传）
    let syncEngine: SyncEngine

    init() {
        let schema = Schema([
            FavoriteModel.self,
            HistoryModel.self,
            ImportedBookModel.self,
            ImportedChapterModel.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        // build 56 · P1-B：启动关键路径不得裸 `try!`——CI 取证（b55/b56 test.log）
        // 显示：单测宿主（App 本体）长寿进程随机崩溃后，磁盘 store 可能处于
        // 半写状态；下一次冷启动 `try! ModelContainer` 读到损坏库直接
        // fatalError，形成「重启即崩」死循环（每条用例 0.000s failed、缺失
        // "Test case started" 行、pid 逐条更替）。真实用户强杀/升级后同理。
        // 本地 store 是云端可同步的缓存（收藏/进度走 SyncEngine），损坏时
        // 删库重建优于启动即死；删后仍建不起来（如磁盘异常）则降级内存态
        // 保 App 可用（收藏/历史可经登录后云端同步拉回）。
        modelContainer = Self.loadContainer(schema: schema, config: config)

        apiClient = APIClient()

        let ctx = modelContainer.mainContext
        // build 50 · 云同步：outbox 队列（AlbumRepository 入队 / SyncEngine 冲浪共用同一份本地状态）
        albumRepository = AlbumRepository(apiClient: apiClient, modelContext: ctx,
                                          syncStore: SyncLocalStore.shared)
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
        syncEngine = SyncEngine(modelContext: ctx)
    }
}

extension EnvironmentValues {
    @Entry var appContainer: AppContainer? = nil
}

extension AppContainer {
    /// 磁盘库优先；打不开（损坏/半写）时删库（含 -shm/-wal sidecar）重建；
    /// 仍失败则降级内存库。守卫用例：Build29RegressionTests.
    /// testAppContainerRecoversFromCorruptStoreInsteadOfTrapping。
    ///
    /// 末级兜底用 `try!` 的说明：内存库构造不触磁盘，仅 schema 非法才可能
    /// 失败——那是编译期可排除的程序员错误，与运行环境态无关；环境态的
    /// 磁盘 trap 已在上两级恢复路径消化。
    private static func loadContainer(
        schema: Schema, config: ModelConfiguration
    ) -> ModelContainer {
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }
        let storePath = config.url.path
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: storePath + suffix)
        }
        if let rebuilt = try? ModelContainer(for: schema, configurations: [config]) {
            return rebuilt
        }
        let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [memoryConfig])
    }
}

extension View {
    func environment(_ container: AppContainer) -> some View {
        self.environment(\.appContainer, container)
    }
}
