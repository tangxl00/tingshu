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
    let playbackRepository: PlaybackRepository

    init(apiClient: APIClient,
         albumRepository: AlbumRepository? = nil,
         msrcAdapter: MsrcAdapter? = nil,
         ytysxsAdapter: YtysxsAdapter? = nil,
         mekuiAdapter: MekuiAdapter? = nil) {
        self.apiClient = apiClient
        self.albumRepository = albumRepository
            ?? AlbumRepository(apiClient: apiClient)
        self.msrcAdapter = msrcAdapter ?? MsrcAdapter(apiClient: apiClient)
        self.ytysxsAdapter = ytysxsAdapter ?? YtysxsAdapter(apiClient: apiClient)
        self.mekuiAdapter = mekuiAdapter ?? MekuiAdapter(apiClient: apiClient)
        self.playbackRepository = PlaybackRepository(
            apiClient: apiClient,
            msrcAdapter: self.msrcAdapter,
            ytysxsAdapter: self.ytysxsAdapter,
            mekuiAdapter: self.mekuiAdapter)
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
        default:
            throw URLError(.unsupportedURL)
        }
    }

    // MARK: - 播放地址（委托 PlaybackRepository）

    func playUrl(src: String, albumId: Int64, chapterIdx: Int, detailPath: String? = nil) async throws -> String {
        try await playbackRepository.getPlayUrl(src: src, albumId: albumId, chapterIdx: chapterIdx)
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
}
