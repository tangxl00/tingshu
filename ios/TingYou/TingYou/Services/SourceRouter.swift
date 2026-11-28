import Foundation

/// 多音源路由（安卓 SourceRouter.kt 对等，P0-3）：
/// search / albumDetail / chapters / playUrl 四链路全部按 src 路由到真实适配器——
/// tingyou → JSON API；bili → BiliAdapter/BiliSearchApi。
/// build 37 · 反馈 1：ting15（听十五）/ mekui（书音FM）下架（同 build 36 删 ting08
/// 模式）——路由 case 与适配器装配摘除，解析器文件保留供离线测试。
/// build 38 · 反馈 1：ting59（59听书网）下架（第 4 次，同一模式）——路由 case、
/// 适配器装配与 Ting59Adapter 整体删除（约定触发：多轮实测站点侧持续失效）。
/// build 45 · 反馈 3：悦听有声书（ytysxs）下架（第 5 次同类下架，用户点名）——
/// 路由 case、适配器装配、YtysxsAdapter 整体删除；存量 ytysxs 书走 default
/// 分支抛 unsupportedURL（UI 层字符串兼容标注「源已下架」）。
/// v2.0.2 · 悦听（ytysxs）重新接入：search/detail/chapters/discoverCategory 走
/// YtysxsAdapter（本地索引 + 公开 JSON），playUrl 委托 PlaybackRepository 的 YTYSXS case。
actor SourceRouter {
    private let apiClient: APIClient
    private let albumRepository: AlbumRepository
    private let biliAdapter: BiliAdapter
    private let ytysxsAdapter: YtysxsAdapter
    let biliSearchApi: BiliSearchApi
    let playbackRepository: PlaybackRepository

    init(apiClient: APIClient,
         albumRepository: AlbumRepository? = nil,
         biliAdapter: BiliAdapter? = nil,
         biliSearchApi: BiliSearchApi? = nil,
         ytysxsAdapter: YtysxsAdapter? = nil) {
        self.apiClient = apiClient
        self.albumRepository = albumRepository
            ?? AlbumRepository(apiClient: apiClient)
        self.biliAdapter = biliAdapter ?? BiliAdapter()
        self.biliSearchApi = biliSearchApi ?? BiliSearchApi(adapter: self.biliAdapter)
        self.ytysxsAdapter = ytysxsAdapter ?? YtysxsAdapter(apiClient: apiClient)
        self.playbackRepository = PlaybackRepository(
            apiClient: apiClient,
            biliAdapter: self.biliAdapter,
            ytysxsAdapter: self.ytysxsAdapter)
    }

    // MARK: - 搜索

    func search(src: String, keyword: String) async throws -> [Album] {
        switch src {
        case SourceRegistry.TINGYOU:
            let result = try await albumRepository.search(keyword: keyword, page: 1)
            return result.items
        case SourceRegistry.BILI:
            let page = try await biliSearchApi.searchAudiobooks(keyword: keyword, page: 1)
            return page.items.map { Self.albumFromBili($0) }
        case SourceRegistry.YTYSXS:
            // v2.0.2：本地索引搜索，零网络——彻底规避站内搜索滑块验证。
            return await ytysxsAdapter.search(keyword: keyword).map { Self.albumFromYtysxs($0) }
        default:
            throw URLError(.unsupportedURL)
        }
    }

    // MARK: - 详情

    func albumDetail(src: String, albumId: Int64, detailPath: String? = nil) async throws -> Album {
        switch src {
        case SourceRegistry.TINGYOU:
            return try await albumRepository.albumDetail(id: albumId)
        case SourceRegistry.BILI:
            // B站不从此入口取详情；详情在导入环节通过 biliAdapter.videoInfo 获取
            throw URLError(.unsupportedURL)
        case SourceRegistry.YTYSXS:
            // v2.0.2：站点详情页解析 og:title/og:image/playlist 引用（带验证页检测）
            let d = try await ytysxsAdapter.detail(albumId: albumId)
            return Album(albumId: albumId, title: d.title, author: nil, teller: nil,
                         coverUrl: d.cover, intro: d.intro,
                         category: nil, categoryId: nil, type: nil, typeId: nil,
                         status: nil, chapterCount: d.playlists.count, updatedAt: nil,
                         playCount: nil, available: true,
                         source: SourceRegistry.YTYSXS, detailPath: String(albumId))
        default:
            throw URLError(.unsupportedURL)
        }
    }

    // MARK: - 章节列表

    func chapters(src: String, albumId: Int64, detailPath: String? = nil) async throws -> [Chapter] {
        switch src {
        case SourceRegistry.TINGYOU:
            return try await albumRepository.chapters(albumId: albumId)
        case SourceRegistry.BILI:
            // v1.4.1 · 发现页点书直达：detailPath 即 bvid，章节 = 分P列表。
            // index 取 0 基（page - 1）：PlaybackRepository BILI 播放口径为
            // page == chapterIdx + 1，且与导入页 ImportedChapterModel 的 chapterIdx（0 基）一致。
            // v1.4.4+ · 详情页章节加载与播放链路对齐：改走 playablePages 复合入口
            //（进程内缓存 → pagelist 轻接口 → view 兜底）。原 videoInfo 直连 view
            // 对匿名高频请求稳定 412，导致详情页标题已出但章节列表为空（testH
            // 长期失败根因）。守卫见 Build44FeedbackTests.testSourceRouterUsesPlayablePages。
            guard let bvid = detailPath, !bvid.isEmpty else { throw URLError(.badURL) }
            let pages = try await biliAdapter.playablePages(bvid: bvid).get()
            return pages.map {
                Chapter(chapterId: $0.cid, index: $0.page - 1, title: $0.part, durationSec: nil)
            }
        case SourceRegistry.YTYSXS:
            // v2.0.2：AudioIgniter playlist JSON → tracks；chapterId 用稳定序号（0 基）。
            // 章节标题已含序号（第xxx集），UI 的 ChapterTitleFormatting 自动去重。
            let tracks = try await ytysxsAdapter.chapters(albumId: albumId)
            guard !tracks.isEmpty else {
                throw YtysxsAdapter.YtysxsUnavailableError(detail: "站点未返回章节")
            }
            return tracks.enumerated().map { idx, t in
                Chapter(chapterId: Int64(idx + 1), index: idx, title: t.title, durationSec: nil)
            }
        default:
            throw URLError(.unsupportedURL)
        }
    }

    // MARK: - 播放地址（委托 PlaybackRepository）

    func playUrl(src: String, albumId: Int64, chapterIdx: Int, detailPath: String? = nil) async throws -> String {
        try await playbackRepository.getPlayUrl(src: src, albumId: albumId, chapterIdx: chapterIdx, detailPath: detailPath)
    }

    // MARK: - 发现页分类（build 21 · 反馈 4/6：按原始音源分类拉取）

    /// 发现页分类数据：tingyou 走 rank API；bili 走分类关键词搜索口径。
    /// 已下架源抛 unsupportedURL，由 UI 层如实标注。
    func discoverCategory(src: String, categoryId: String, page: Int) async throws -> (albums: [Album], hasMore: Bool) {
        switch src {
        case SourceRegistry.TINGYOU:
            let result = try await albumRepository.rank(section: categoryId, page: page)
            return (result.items, result.hasMore)
        case SourceRegistry.BILI:
            // v1.4.1 · B站「分类」实为该分类关键词的搜索（沿用原 BiliHomeScreen 的口径：
            // 取 BiliCategories.ALL 对应分类的首个关键词调 searchAudiobooks）
            let keyword = BiliCategories.ALL.first(where: { $0.key == categoryId })?.keywords.first ?? categoryId
            let result = try await biliSearchApi.searchAudiobooks(keyword: keyword, page: page)
            return (result.items.map { Self.albumFromBili($0) }, result.hasMore)
        case SourceRegistry.YTYSXS:
            // v2.0.2：本地索引按分类过滤（零网络，封面随索引携带）
            let out = await ytysxsAdapter.categoryRows(categoryId: categoryId, page: page)
            return (out.rows.map { Self.albumFromYtysxs($0) }, out.hasMore)
        default:
            throw URLError(.unsupportedURL) // 该源暂不支持发现页
        }
    }

    // MARK: - 映射辅助

    /// v1.4.1：B站 Album 的稳定 albumId——由 bvid 计算（FNV-1a 64）。
    /// 背景：recordHistory 按 (src, albumId) 去重，此前 albumId 恒为 0 会导致
    /// 不同 B站 书共用同一条历史互相覆盖（续播错乱）；同时 Album.id = albumId，
    /// 恒 0 会造成发现页/搜索列表 ForEach 重复 id。播放链路不消费该值
    /// （PlaybackRepository BILI 以 detailPath=bvid 为准，章节解析亦同）。
    static func biliAlbumId(from bvid: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a offset basis
        for byte in bvid.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3 // FNV-1a prime
        }
        return Int64(bitPattern: hash)
    }

    private static func albumFromBili(_ item: BiliSearchApi.SearchResult) -> Album {
        Album(albumId: biliAlbumId(from: item.bvid), // v1.4.1：bvid 稳定哈希（原恒 0），见 biliAlbumId 注释
              title: item.title, author: item.author, teller: nil,
              coverUrl: item.coverUrl, intro: item.description,
              category: nil, categoryId: nil, type: nil, typeId: nil,
              status: nil, chapterCount: nil, updatedAt: nil,
              playCount: item.play, available: !item.paid,
              source: SourceRegistry.BILI, detailPath: item.bvid)
    }

    /// v2.0.2：本地索引行 → Album（albumId = 站点书 ID，detailPath 同为书 ID 字符串）。
    private static func albumFromYtysxs(_ row: YtysxsAdapter.IndexRow) -> Album {
        Album(albumId: row.bookId, title: row.title, author: nil, teller: nil,
              coverUrl: row.cover, intro: nil,
              category: row.category, categoryId: nil, type: nil, typeId: nil,
              status: nil, chapterCount: nil, updatedAt: nil,
              playCount: nil, available: true,
              source: SourceRegistry.YTYSXS, detailPath: String(row.bookId))
    }

}
