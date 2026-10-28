import Foundation

/// 播放地址解析仓库（安卓 PlaybackRepository.kt 对等）：按 src 路由 getPlayUrl。
/// - tingyou → API play 端点；
/// build 37 · 反馈 1：ting15（听十五）/ mekui（书音FM）下架（同 build 36 删
/// ting08 模式）——播放路由 case 与适配器装配摘除。
/// build 38 · 反馈 1：ting59（59听书网）下架（第 4 次）——适配器整体删除，
/// 播放路由 case 摘除；init 4 → 3 参数。
/// build 45 · 反馈 3：悦听有声书（ytysxs）下架（第 5 次同类下架，用户点名）——
/// 适配器整体删除、播放路由 case 摘除、init 3 → 2 参数。存量 ytysxs 书走
/// default 抛 unsupportedURL（describePlaybackError 字符串兼容报「源已下架」）。
final class PlaybackRepository: Sendable {
    private let apiClient: APIClient
    private let biliAdapter: BiliAdapter

    init(apiClient: APIClient,
         biliAdapter: BiliAdapter) {
        self.apiClient = apiClient
        self.biliAdapter = biliAdapter
    }

    /// 解析占位 URI 为真实音频直链（AVAssetResourceLoaderDelegate 惰性调用）。
    func getPlayUrl(src: String, albumId: Int64, chapterIdx: Int, detailPath: String? = nil) async throws -> String {
        try await getPlayUrl(src: src, albumId: albumId, chapterIdx: chapterIdx, detailPath: detailPath, markPaid: true)
    }

    /// build 48 · 需求 4（B站取流超时 · 镜像重试）：解析占位 URI 为「主选直链
    /// + backup 镜像」候选链（首位为主选，语义上即 getPlayUrl 的返回值）。
    /// - B站：playurl 响应的 baseUrl + backup_url/backupUrl/backupUrls 全链
    ///   （白名单内去重）——真机《择日飞升》取证：主选镜像
    ///   upos-sz-estgcos.bilivideo.com 206 video/mp4 但 20s 零字节到达
    ///   （缓冲挂起），watchdog 据此自动换下一镜像重试；
    /// - 其它源：单元素链（无镜像语义，行为与 getPlayUrl 一致）。
    func getPlayUrlCandidates(src: String, albumId: Int64, chapterIdx: Int, detailPath: String? = nil) async throws -> [String] {
        guard src == SourceRegistry.BILI else {
            return [try await getPlayUrl(src: src, albumId: albumId, chapterIdx: chapterIdx, detailPath: detailPath)]
        }
        guard let bvid = detailPath, !bvid.isEmpty else {
            throw URLError(.badURL)
        }
        let pagesResult = await biliAdapter.playablePages(bvid: bvid)
        let pages = try pagesResult.get()
        guard let page = pages.first(where: { $0.page == chapterIdx + 1 }) else {
            throw URLError(.resourceUnavailable)
        }
        let streamResult = await biliAdapter.audioStreamUrlCandidates(bvid: bvid, cid: page.cid)
        let candidates = try streamResult.get()
        guard !candidates.isEmpty else { throw URLError(.badServerResponse) }
        return candidates
    }

    /// 增强 5.3 预取入口：markPaid=false 时预取失败静默处理（不打标、不弹验证
    /// 流程），供下一章预取使用；正常播放路径仍走上面的默认入口。
    /// build 37：msrc 源下架后该参数暂无消费方，为保持 PlaybackManager 调用
    /// 接口稳定（markPaid:false 预取口径）而保留。
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
        case SourceRegistry.BILI:
            // B站播放：detailPath 即 bvid，章节 index 映射到分P cid
            guard let bvid = detailPath, !bvid.isEmpty else {
                throw URLError(.badURL)
            }
            // build 44 · 反馈 3（Cannot Open）：分P获取改走 playablePages
            //（缓存 → pagelist 轻接口 → view 兜底）。原先每章都拉 view：
            // 3 请求/章 + 预取放大触发 412 风控，resolve 失败后 AVFoundation
            // 吞掉错误显示 Cannot Open。沙箱取证：view 连续 3 次 412，
            // pagelist 连续 3 次 200（2026-10-27）。
            let pagesResult = await biliAdapter.playablePages(bvid: bvid)
            let pages = try pagesResult.get()
            guard let page = pages.first(where: { $0.page == chapterIdx + 1 }) else {
                throw URLError(.resourceUnavailable)
            }
            let streamResult = await biliAdapter.audioStreamUrl(bvid: bvid, cid: page.cid)
            return try streamResult.get()
        default:
            throw URLError(.unsupportedURL)
        }
    }
}
