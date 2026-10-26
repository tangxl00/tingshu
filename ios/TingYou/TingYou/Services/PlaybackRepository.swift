import Foundation

/// 播放地址解析仓库（安卓 PlaybackRepository.kt 对等）：按 src 路由 getPlayUrl。
/// - tingyou → API play 端点；
/// - ting15 → MsrcAdapter 两步 token；
/// - ytysxs → 章节直链透传（白名单自检）；
/// - mekui → ecmsapi wapseries 预签名。
final class PlaybackRepository: Sendable {
    private let apiClient: APIClient
    private let msrcAdapter: MsrcAdapter
    private let ytysxsAdapter: YtysxsAdapter
    private let mekuiAdapter: MekuiAdapter
    private let biliAdapter: BiliAdapter
    private let ting59Adapter: Ting59Adapter

    init(apiClient: APIClient,
         msrcAdapter: MsrcAdapter,
         ytysxsAdapter: YtysxsAdapter,
         mekuiAdapter: MekuiAdapter,
         biliAdapter: BiliAdapter,
         ting59Adapter: Ting59Adapter) {
        self.apiClient = apiClient
        self.msrcAdapter = msrcAdapter
        self.ytysxsAdapter = ytysxsAdapter
        self.mekuiAdapter = mekuiAdapter
        self.biliAdapter = biliAdapter
        self.ting59Adapter = ting59Adapter
    }

    /// 解析占位 URI 为真实音频直链（AVAssetResourceLoaderDelegate 惰性调用）。
    func getPlayUrl(src: String, albumId: Int64, chapterIdx: Int, detailPath: String? = nil) async throws -> String {
        try await getPlayUrl(src: src, albumId: albumId, chapterIdx: chapterIdx, detailPath: detailPath, markPaid: true)
    }

    /// 增强 5.3 预取入口：markPaid=false 时 msrc 两步 token 探测到付费章静默失败
    /// （不打标、不弹验证流程），供下一章预取使用；正常播放路径仍走上面的默认入口。
    func getPlayUrl(src: String, albumId: Int64, chapterIdx: Int, detailPath: String? = nil, markPaid: Bool) async throws -> String {
        switch src {
        case SourceRegistry.TINGYOU:
            let resp: PlayResponse = try await apiClient.postForm("play", fields: [
                "album_id": String(albumId),
                "chapter_idx": String(chapterIdx),
            ])
            guard let url = resp.playUrl, !url.isEmpty else {
                throw URLError(.badServerResponse)
            }
            return url
        case SourceRegistry.TING15:
            return try await msrcAdapter.getPlayUrl(src: src, bookId: albumId, page: chapterIdx,
                                                    markPaid: markPaid)
        case SourceRegistry.YTYXSX:
            let chapters = try await ytysxsAdapter.chapters(albumId: albumId)
            guard let chapter = chapters.first(where: { $0.index == chapterIdx }) else {
                throw URLError(.resourceUnavailable)
            }
            return try ytysxsAdapter.playUrl(chapter: chapter)
        case SourceRegistry.MEKUI:
            let detail = try await mekuiAdapter.detail(id: String(albumId))
            return try await mekuiAdapter.getPlayUrl(albumId: String(albumId),
                                                     chapterIdx: chapterIdx,
                                                     knownChapters: detail.chapters)
        case SourceRegistry.BILI:
            // B站播放：detailPath 即 bvid，章节 index 映射到分P cid
            guard let bvid = detailPath, !bvid.isEmpty else {
                throw URLError(.badURL)
            }
            let infoResult = await biliAdapter.videoInfo(bvid: bvid)
            let info = try infoResult.get()
            guard let page = info.pages.first(where: { $0.page == chapterIdx + 1 }) else {
                throw URLError(.resourceUnavailable)
            }
            let streamResult = await biliAdapter.audioStreamUrl(bvid: bvid, cid: page.cid)
            return try streamResult.get()
        case SourceRegistry.TING59:
            // P0-2：从 detailPath 解析站点 bookId（如 "/mp3/19745.html" → "19745"），
            // 避免使用本地自增 albumId 导致 404
            let siteBookId: String
            if let path = detailPath, !path.isEmpty {
                siteBookId = path.replacingOccurrences(of: "/mp3/", with: "")
                    .replacingOccurrences(of: ".html", with: "")
            } else {
                siteBookId = String(albumId)
            }
            let doc = try await ting59Adapter.fetchPlayPage(bookId: siteBookId, line: 0, index: chapterIdx)
            let url = try Ting59PlayParser.extractAudioUrl(html: doc)
            return url
        default:
            throw URLError(.unsupportedURL)
        }
    }
}
