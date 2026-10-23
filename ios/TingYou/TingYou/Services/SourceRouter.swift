import Foundation

/// 多音源路由（安卓 SourceRouter.kt 对等，P0-3）：
/// search / albumDetail / chapters / playUrl 四链路全部按 src 路由到真实适配器——
/// tingyou → JSON API；ting15/ting08 → MsrcAdapter（HTML + 两步 token）；
/// ytysxs → YtysxsAdapter（WordPress + AudioIgniter，反爬走 AntibotException）；
/// mekui → MekuiAdapter（ecmsapi + wapseries 签名）。
actor SourceRouter {
    private let apiClient: APIClient
    private let albumRepository: AlbumRepository
    private let msrcAdapter: MsrcAdapter
    private let ytysxsAdapter: YtysxsAdapter
    private let mekuiAdapter: MekuiAdapter
    private let biliAdapter: BiliAdapter
    let biliSearchApi: BiliSearchApi
    private let ting59Adapter: Ting59Adapter
    let playbackRepository: PlaybackRepository

    init(apiClient: APIClient,
         albumRepository: AlbumRepository? = nil,
         msrcAdapter: MsrcAdapter? = nil,
         ytysxsAdapter: YtysxsAdapter? = nil,
         mekuiAdapter: MekuiAdapter? = nil,
         biliAdapter: BiliAdapter? = nil,
         biliSearchApi: BiliSearchApi? = nil,
         ting59Adapter: Ting59Adapter? = nil) {
        self.apiClient = apiClient
        self.albumRepository = albumRepository
            ?? AlbumRepository(apiClient: apiClient)
        self.msrcAdapter = msrcAdapter ?? MsrcAdapter(apiClient: apiClient)
        self.ytysxsAdapter = ytysxsAdapter ?? YtysxsAdapter(apiClient: apiClient)
        self.mekuiAdapter = mekuiAdapter ?? MekuiAdapter(apiClient: apiClient)
        self.biliAdapter = biliAdapter ?? BiliAdapter()
        self.biliSearchApi = biliSearchApi ?? BiliSearchApi(adapter: self.biliAdapter)
        self.ting59Adapter = ting59Adapter ?? Ting59Adapter()
        self.playbackRepository = PlaybackRepository(
            apiClient: apiClient,
            msrcAdapter: self.msrcAdapter,
            ytysxsAdapter: self.ytysxsAdapter,
            mekuiAdapter: self.mekuiAdapter,
            biliAdapter: self.biliAdapter,
            ting59Adapter: self.ting59Adapter)
    }

    // MARK: - 搜索

    func search(src: String, keyword: String) async throws -> [Album] {
        switch src {
        case SourceRegistry.TINGYOU:
            let result = try await albumRepository.search(keyword: keyword, page: 1)
            return result.items
        case SourceRegistry.TING15, SourceRegistry.TING08:
            let items = try await msrcAdapter.search(src: src, keyword: keyword)
            return items.map { Self.albumFromMsrc($0, src: src) }
        case SourceRegistry.YTYXSX:
            let items = try await ytysxsAdapter.search(keyword: keyword)
            return items.map { Self.albumFromYtysxs($0) }
        case SourceRegistry.MEKUI:
            let page = try await mekuiAdapter.search(keyword: keyword, page: 1)
            return page.items.map { Self.albumFromMekui($0) }
        case SourceRegistry.BILI:
            let page = try await biliSearchApi.searchAudiobooks(keyword: keyword, page: 1)
            return page.items.map { Self.albumFromBili($0) }
        case SourceRegistry.TING59:
            let result = try await ting59Adapter.search(query: keyword, page: 1)
            return result.list.map { Self.albumFromTing59($0) }
        default:
            throw URLError(.unsupportedURL)
        }
    }

    // MARK: - 详情

    func albumDetail(src: String, albumId: Int64, detailPath: String? = nil) async throws -> Album {
        switch src {
        case SourceRegistry.TINGYOU:
            return try await albumRepository.albumDetail(id: albumId)
        case SourceRegistry.TING15, SourceRegistry.TING08:
            guard let path = detailPath, !path.isEmpty else { throw URLError(.badURL) }
            let d = try await msrcAdapter.detail(src: src, detailPath: path)
            return Album(albumId: albumId, title: d.title, author: d.author, teller: d.teller,
                         coverUrl: d.cover, intro: d.intro, category: nil, categoryId: nil,
                         type: nil, typeId: nil, status: nil, chapterCount: d.chapterCount,
                         updatedAt: nil, playCount: nil, available: true, source: src,
                         detailPath: path)
        case SourceRegistry.YTYXSX:
            let d = try await ytysxsAdapter.detail(albumId: albumId)
            return Album(albumId: albumId, title: d.title, author: nil, teller: nil,
                         coverUrl: d.cover, intro: d.intro, category: nil, categoryId: nil,
                         type: nil, typeId: nil, status: nil, chapterCount: nil,
                         updatedAt: nil, playCount: nil, available: true, source: src,
                         detailPath: "/\(albumId).html")
        case SourceRegistry.MEKUI:
            let d = try await mekuiAdapter.detail(id: String(albumId))
            return Album(albumId: albumId, title: d.title, author: d.artist, teller: d.player,
                         coverUrl: d.cover.isEmpty ? nil : d.cover, intro: d.description,
                         category: d.category, categoryId: nil, type: nil, typeId: nil,
                         status: nil, chapterCount: d.chapters.count, updatedAt: nil,
                         playCount: nil, available: true, source: src,
                         detailPath: "/\(albumId)")
        case SourceRegistry.BILI:
            // B站不从此入口取详情；详情在导入环节通过 biliAdapter.videoInfo 获取
            throw URLError(.unsupportedURL)
        case SourceRegistry.TING59:
            guard let path = detailPath, !path.isEmpty else { throw URLError(.badURL) }
            let bookId = path.replacingOccurrences(of: "/mp3/", with: "").replacingOccurrences(of: ".html", with: "")
            let d = try await ting59Adapter.bookDetail(bookId: bookId)
            return Album(albumId: albumId, title: d.book.title, author: d.book.author,
                         teller: d.book.narrator, coverUrl: d.coverUrl, intro: d.description,
                         category: d.book.category, categoryId: nil, type: nil, typeId: nil,
                         status: nil, chapterCount: d.chapters.count,
                         // ting59 更新时间为中文日期串，无法无损转 Int64 时间戳，不做有损转换
                         updatedAt: nil, playCount: nil, available: true, source: src,
                         detailPath: path)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    // MARK: - 章节列表

    func chapters(src: String, albumId: Int64, detailPath: String? = nil) async throws -> [Chapter] {
        switch src {
        case SourceRegistry.TINGYOU:
            return try await albumRepository.chapters(albumId: albumId)
        case SourceRegistry.TING15, SourceRegistry.TING08:
            guard let path = detailPath, !path.isEmpty else { throw URLError(.badURL) }
            let d = try await msrcAdapter.detail(src: src, detailPath: path)
            return d.chapters.map {
                Chapter(chapterId: Int64($0.page), index: $0.page, title: $0.title, durationSec: nil)
            }
        case SourceRegistry.YTYXSX:
            let list = try await ytysxsAdapter.chapters(albumId: albumId)
            return list.map {
                Chapter(chapterId: Int64($0.index), index: $0.index, title: $0.title, durationSec: nil)
            }
        case SourceRegistry.MEKUI:
            let d = try await mekuiAdapter.detail(id: String(albumId))
            return d.chapters.map {
                Chapter(chapterId: Int64($0.index), index: $0.index, title: $0.title, durationSec: nil)
            }
        case SourceRegistry.BILI:
            // B站章节在导入时通过 videoInfo 获取并存入 ImportedChapterModel
            throw URLError(.unsupportedURL)
        case SourceRegistry.TING59:
            guard let path = detailPath, !path.isEmpty else { throw URLError(.badURL) }
            let bookId = path.replacingOccurrences(of: "/mp3/", with: "").replacingOccurrences(of: ".html", with: "")
            let d = try await ting59Adapter.bookDetail(bookId: bookId)
            return d.chapters.map {
                Chapter(chapterId: Int64($0.index), index: $0.index, title: $0.title, durationSec: nil)
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

    /// 发现页分类数据：tingyou 走 rank API；ting15/ting08 走分类页 HTML 解析。
    /// 不支持的源（mekui/ytysxs）抛 unsupportedURL，由 UI 层如实标注。
    func discoverCategory(src: String, categoryId: String, page: Int) async throws -> (albums: [Album], hasMore: Bool) {
        switch src {
        case SourceRegistry.TINGYOU:
            let result = try await albumRepository.rank(section: categoryId, page: page)
            return (result.items, result.hasMore)
        case SourceRegistry.TING15, SourceRegistry.TING08:
            let result = try await msrcAdapter.category(src: src, categoryId: categoryId, page: page)
            return (result.items.map { Self.albumFromMsrc($0, src: src) }, result.hasMore)
        case SourceRegistry.TING59:
            let result = try await ting59Adapter.category(categoryId: categoryId, page: page)
            return (result.books.map { Self.albumFromTing59($0) }, result.hasMore)
        default:
            throw URLError(.unsupportedURL) // 该源暂不支持发现页
        }
    }

    // MARK: - 映射辅助

    private static func albumFromMsrc(_ item: MsrcHtml.MsrcSearchItem, src: String) -> Album {
        Album(albumId: Int64(item.bookId) ?? 0, title: item.title, author: item.author,
              teller: item.teller, coverUrl: item.cover, intro: nil, category: nil, categoryId: nil,
              type: nil, typeId: nil, status: nil, chapterCount: nil, updatedAt: nil,
              playCount: nil, available: true, source: src, detailPath: item.detailPath)
    }

    private static func albumFromYtysxs(_ item: YtysxsAdapter.YtysxsSearchItem) -> Album {
        Album(albumId: item.bookId, title: item.title, author: nil, teller: nil,
              coverUrl: nil, intro: nil, category: nil, categoryId: nil, type: nil, typeId: nil,
              status: nil, chapterCount: nil, updatedAt: nil, playCount: nil, available: true,
              source: SourceRegistry.YTYXSX, detailPath: item.detailPath)
    }

    private static func albumFromMekui(_ item: MekuiAdapter.MekuiSearchItem) -> Album {
        Album(albumId: Int64(item.id) ?? 0, title: item.title, author: item.playadmin,
              teller: item.player, coverUrl: item.titlepic.isEmpty ? nil : item.titlepic,
              intro: nil, category: nil, categoryId: nil, type: nil, typeId: nil, status: nil,
              chapterCount: nil, updatedAt: nil, playCount: nil, available: true,
              source: SourceRegistry.MEKUI, detailPath: "/\(item.id)")
    }

    private static func albumFromBili(_ item: BiliSearchApi.SearchResult) -> Album {
        Album(albumId: 0, // B站搜索结果是视频，albumId 在导入阶段生成
              title: item.title, author: item.author, teller: nil,
              coverUrl: item.coverUrl, intro: item.description,
              category: nil, categoryId: nil, type: nil, typeId: nil,
              status: nil, chapterCount: nil, updatedAt: nil,
              playCount: item.play, available: !item.paid,
              source: SourceRegistry.BILI, detailPath: item.bvid)
    }

    private static func albumFromTing59(_ item: Ting59Adapter.Ting59SearchItem) -> Album {
        Album(albumId: Int64(item.id) ?? 0, title: item.title, author: item.author,
              teller: item.narrator, coverUrl: nil, intro: nil,
              category: item.category, categoryId: nil, type: nil, typeId: nil,
              status: nil, chapterCount: nil,
              // ting59 更新时间为中文日期串，无法无损转 Int64 时间戳，不做有损转换
              updatedAt: nil,
              playCount: nil, available: true, source: SourceRegistry.TING59,
              detailPath: item.detailUrl)
    }
}
