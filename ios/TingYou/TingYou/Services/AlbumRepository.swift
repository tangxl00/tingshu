import Foundation
import SwiftData

actor AlbumRepository {
    private let apiClient: APIClient
    private let modelContext: ModelContext
    private var cache: [String: Album] = [:]
    private let cacheLock = NSLock()

    init(apiClient: APIClient, modelContext: ModelContext) {
        self.apiClient = apiClient
        self.modelContext = modelContext
    }

    func rank(section: String, page: Int) async throws -> PagedResult<Album> {
        let resp: RankResponse = try await apiClient.get("rank", queries: ["section": section, "page": String(page)])
        let albums = resp.items.map { $0.toDomain() }
        return PagedResult(items: albums, hasMore: resp.hasMore ?? false)
    }

    func category(page: Int, catId: Int? = nil, typeId: Int? = nil, status: Int? = nil, sort: String? = nil) async throws -> PagedResult<Album> {
        var q: [String: String] = ["page": String(page)]
        if let c = catId { q["category"] = String(c); q["cat_id"] = String(c) }
        if let t = typeId { q["type"] = String(t); q["type_id"] = String(t) }
        if let s = status { q["status"] = String(s) }
        if let so = sort { q["sort"] = so }
        let resp: CategoryResponse = try await apiClient.get("category", queries: q)
        let albums = resp.data.map { $0.toDomain() }
        return PagedResult(items: albums, hasMore: (resp.page ?? 0) < (resp.pages ?? 0))
    }

    func filters() async throws -> Filters {
        let resp: FiltersResponse = try await apiClient.get("filters")
        return resp.toDomain()
    }

    func albumDetail(id: Int64) async throws -> Album {
        let resp: AlbumDto = try await apiClient.get("album/\(id)")
        return resp.toDomain()
    }

    func chapters(albumId: Int64) async throws -> [Chapter] {
        let resp: ChaptersResponse = try await apiClient.get("chapters/\(albumId)")
        return resp.chapters.map { $0.toDomain() }
    }

    func search(keyword: String, page: Int) async throws -> PagedResult<Album> {
        let req = SearchRequest(keyword: keyword, page: page)
        let resp: SearchResponse = try await apiClient.post("search", body: req)
        let albums = resp.results.map { $0.toDomain() }
        return PagedResult(items: albums, hasMore: resp.hasMore ?? false)
    }

    func playUrl(albumId: Int64, chapterIdx: Int) async throws -> String {
        let resp: PlayResponse = try await apiClient.postForm("play", fields: [
            "album_id": String(albumId),
            "chapter_idx": String(chapterIdx)
        ])
        guard let url = resp.playUrl, !url.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return url
    }

    func cachedAlbum(src: String, albumId: Int64) -> Album? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache["\(src)|\(albumId)"]
    }

    func putCache(album: Album) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache["\(album.source)|\(album.albumId)"] = album
        if cache.count > 8 {
            cache.removeValue(forKey: cache.keys.first!)
        }
    }
}
