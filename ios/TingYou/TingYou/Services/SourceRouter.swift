import Foundation

/// 多音源路由（安卓 SourceRouter.kt 对等，P0-3）：
/// search / albumDetail / chapters / playUrl 四链路全部按 src 路由到真实适配器——
/// tingyou → JSON API；ytysxs → YtysxsAdapter（WordPress + AudioIgniter，
/// 反爬走 AntibotException）；bili → BiliAdapter/BiliSearchApi。
/// build 37 · 反馈 1：ting15（听十五）/ mekui（书音FM）下架（同 build 36 删 ting08
/// 模式）——路由 case 与适配器装配摘除，解析器文件保留供离线测试。
/// build 38 · 反馈 1：ting59（59听书网）下架（第 4 次，同一模式）——路由 case、
/// 适配器装配与 Ting59Adapter 整体删除（约定触发：多轮实测站点侧持续失效）。
actor SourceRouter {
    private let apiClient: APIClient
    private let albumRepository: AlbumRepository
    private let ytysxsAdapter: YtysxsAdapter
    private let biliAdapter: BiliAdapter
    let biliSearchApi: BiliSearchApi
    let playbackRepository: PlaybackRepository

    init(apiClient: APIClient,
         albumRepository: AlbumRepository? = nil,
         ytysxsAdapter: YtysxsAdapter? = nil,
         biliAdapter: BiliAdapter? = nil,
         biliSearchApi: BiliSearchApi? = nil) {
        self.apiClient = apiClient
        self.albumRepository = albumRepository
            ?? AlbumRepository(apiClient: apiClient)
        self.ytysxsAdapter = ytysxsAdapter ?? YtysxsAdapter(apiClient: apiClient)
        self.biliAdapter = biliAdapter ?? BiliAdapter()
        self.biliSearchApi = biliSearchApi ?? BiliSearchApi(adapter: self.biliAdapter)
        self.playbackRepository = PlaybackRepository(
            apiClient: apiClient,
            ytysxsAdapter: self.ytysxsAdapter,
            biliAdapter: self.biliAdapter)
    }

    // MARK: - 搜索

    func search(src: String, keyword: String) async throws -> [Album] {
        switch src {
        case SourceRegistry.TINGYOU:
            let result = try await albumRepository.search(keyword: keyword, page: 1)
            return result.items
        case SourceRegistry.YTYXSX:
            let items = try await ytysxsAdapter.search(keyword: keyword)
            return items.map { Self.albumFromYtysxs($0) }
        case SourceRegistry.BILI:
            let page = try await biliSearchApi.searchAudiobooks(keyword: keyword, page: 1)
            return page.items.map { Self.albumFromBili($0) }
        default:
            throw URLError(.unsupportedURL)
        }
    }

    // MARK: - 详情

    func albumDetail(src: String, albumId: Int64, detailPath: String? = nil) async throws -> Album {
        switch src {
        case SourceRegistry.TINGYOU:
            return try await albumRepository.albumDetail(id: albumId)
        case SourceRegistry.YTYXSX:
            let d = try await ytysxsAdapter.detail(albumId: albumId)
            return Album(albumId: albumId, title: d.title, author: nil, teller: nil,
                         coverUrl: d.cover, intro: d.intro, category: nil, categoryId: nil,
                         type: nil, typeId: nil, status: nil, chapterCount: nil,
                         updatedAt: nil, playCount: nil, available: true, source: src,
                         detailPath: "/\(albumId).html")
        case SourceRegistry.BILI:
            // B站不从此入口取详情；详情在导入环节通过 biliAdapter.videoInfo 获取
            throw URLError(.unsupportedURL)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    // MARK: - 章节列表

    func chapters(src: String, albumId: Int64, detailPath: String? = nil) async throws -> [Chapter] {
        switch src {
        case SourceRegistry.TINGYOU:
            return try await albumRepository.chapters(albumId: albumId)
        case SourceRegistry.YTYXSX:
            let list = try await ytysxsAdapter.chapters(albumId: albumId)
            return list.map {
                Chapter(chapterId: Int64($0.index), index: $0.index, title: $0.title, durationSec: nil)
            }
        case SourceRegistry.BILI:
            // v1.4.1 · 发现页点书直达：detailPath 即 bvid，章节 = 分P列表。
            // index 取 0 基（page - 1）：PlaybackRepository BILI 播放口径为
            // page == chapterIdx + 1，且与导入页 ImportedChapterModel 的 chapterIdx（0 基）一致。
            guard let bvid = detailPath, !bvid.isEmpty else { throw URLError(.badURL) }
            let info = try await biliAdapter.videoInfo(bvid: bvid).get()
            return info.pages.map {
                Chapter(chapterId: $0.cid, index: $0.page - 1, title: $0.part, durationSec: nil)
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
    /// 不支持的源（ytysxs）抛 unsupportedURL，由 UI 层如实标注。
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
        default:
            throw URLError(.unsupportedURL) // 该源暂不支持发现页
        }
    }

    // MARK: - 映射辅助

    private static func albumFromYtysxs(_ item: YtysxsAdapter.YtysxsSearchItem) -> Album {
        Album(albumId: item.bookId, title: item.title, author: nil, teller: nil,
              coverUrl: nil, intro: nil, category: nil, categoryId: nil, type: nil, typeId: nil,
              status: nil, chapterCount: nil, updatedAt: nil, playCount: nil, available: true,
              source: SourceRegistry.YTYXSX, detailPath: item.detailPath)
    }

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

}
