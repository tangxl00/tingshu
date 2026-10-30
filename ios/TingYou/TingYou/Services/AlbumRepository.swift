import Foundation
import SwiftData

/// 播放历史落库出口（Bug 2）：PlaybackManager 只依赖此协议，AppContainer 注入 AlbumRepository，
/// 单测可注入假实现验证调用路径。
protocol PlaybackHistoryRecording: Sendable {
    /// 起播 / 切章 / 每 ~5s / 暂停时上报；按 (src, albumId) upsert，同一本书只保留一条。
    func recordHistory(album: Album, chapter: Chapter, positionMs: Int64, durationMs: Int64) async
}

// build 19 返修：补上协议遵循声明——方法签名已匹配但类型未声明遵循，
// AppContainer 里 `playbackManager.historyRecorder = albumRepository` 编译不过（CI run 39360876825 唯一错误）。
// actor 隔离天然满足协议的 async 与 Sendable 要求。
actor AlbumRepository: PlaybackHistoryRecording {
    private let apiClient: APIClient
    private let modelContext: ModelContext?
    /// build 50 · 云同步 outbox 入队出口（未登录时入队方法内部直接跳过）
    private let syncStore: SyncLocalStore?
    private var cache: [String: Album] = [:]
    private let cacheLock = NSLock()

    init(apiClient: APIClient, modelContext: ModelContext? = nil,
         syncStore: SyncLocalStore? = nil) {
        self.apiClient = apiClient
        self.modelContext = modelContext
        self.syncStore = syncStore
    }

    // MARK: - 播放历史 / 收藏落库（Bug 2）

    /// mainContext 必须在主线程使用：所有 SwiftData 写入统一经 MainActor.run 执行。
    /// 落库失败静默降级（历史/收藏是体验增强，不阻断播放）。
    func recordHistory(album: Album, chapter: Chapter, positionMs: Int64, durationMs: Int64) async {
        guard let ctx = modelContext else { return }
        let src = album.source
        let albumId = album.albumId
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let pos = max(0, positionMs)
        let dur = max(0, durationMs)
        await MainActor.run {
            let fd = FetchDescriptor<HistoryModel>(
                predicate: #Predicate { $0.src == src && $0.albumId == albumId })
            if let h = (try? ctx.fetch(fd))?.first {
                h.albumTitle = album.title
                h.coverUrl = album.coverUrl
                h.chapterIdx = chapter.index
                h.chapterTitle = chapter.title
                h.positionMs = pos
                h.durationMs = dur
                h.detailPath = album.detailPath
                h.updatedAt = now
            } else {
                ctx.insert(HistoryModel(src: src, albumId: albumId, albumTitle: album.title,
                                        coverUrl: album.coverUrl, chapterIdx: chapter.index,
                                        chapterTitle: chapter.title, positionMs: pos, durationMs: dur,
                                        detailPath: album.detailPath, updatedAt: now))
            }
            do { try ctx.save() } catch {
                // build 19 P1-1：落库失败不允许静默——打印错误便于排查（历史为体验增强，仍不阻断播放）
                print("recordHistory save failed [\(src)|\(albumId)]: \(error)")
            }
        }
        // build 50 · 云同步：进度入 outbox（未登录跳过；outbox 批内压缩兜底 5s 节流）
        syncStore?.enqueueProgress(src: src, albumId: albumId, title: album.title,
                                   coverUrl: album.coverUrl, chapterIdx: chapter.index,
                                   positionMs: pos, durationMs: dur,
                                   detailPath: album.detailPath)
    }

    /// 收藏状态查询（书架 @Query 之外的自查入口；PlayerScreen 收藏按钮初始化用）
    func isFavorite(src: String, albumId: Int64) async -> Bool {
        guard let ctx = modelContext else { return false }
        return await MainActor.run {
            let fd = FetchDescriptor<FavoriteModel>(
                predicate: #Predicate { $0.src == src && $0.albumId == albumId })
            return ((try? ctx.fetch(fd))?.first) != nil
        }
    }

    /// 写入收藏（同一本书已收藏则幂等跳过）
    func addFavorite(album: Album) async {
        guard let ctx = modelContext else { return }
        let src = album.source
        let albumId = album.albumId
        await MainActor.run {
            let fd = FetchDescriptor<FavoriteModel>(
                predicate: #Predicate { $0.src == src && $0.albumId == albumId })
            guard ((try? ctx.fetch(fd))?.first) == nil else { return }
            ctx.insert(FavoriteModel(src: src, albumId: albumId, title: album.title,
                                      author: album.author, teller: album.teller,
                                      coverUrl: album.coverUrl, chapterCount: album.chapterCount,
                                      status: album.status, lastChapterIdx: nil,
                                      detailPath: album.detailPath))
            do { try ctx.save() } catch {
                // build 19 P1-1：收藏写库失败不允许静默
                print("addFavorite save failed [\(src)|\(albumId)]: \(error)")
            }
            // build 50 · 云同步：收藏 upsert 入 outbox（未登录跳过）
            self.syncStore?.enqueueFavoriteUpsert(src: src, albumId: albumId,
                                                  title: album.title, author: album.author,
                                                  coverUrl: album.coverUrl,
                                                  detailPath: album.detailPath)
        }
    }

    /// 删除收藏（detailPath：build 50 云同步 bili 音源的 album_key 需要 bvid）
    func removeFavorite(src: String, albumId: Int64, detailPath: String? = nil) async {
        guard let ctx = modelContext else { return }
        await MainActor.run {
            let fd = FetchDescriptor<FavoriteModel>(
                predicate: #Predicate { $0.src == src && $0.albumId == albumId })
            for m in (try? ctx.fetch(fd)) ?? [] { ctx.delete(m) }
            do { try ctx.save() } catch {
                // build 19 P1-1：删收藏失败不允许静默
                print("removeFavorite save failed [\(src)|\(albumId)]: \(error)")
            }
            // build 50 · 云同步：收藏删除（墓碑）入 outbox（未登录跳过）
            self.syncStore?.enqueueFavoriteDelete(src: src, albumId: albumId,
                                                  detailPath: detailPath)
        }
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
