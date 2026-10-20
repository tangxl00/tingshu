import UIKit

/// 封面图缓存（增强 5.2；build 19 P2-1/P2-3 加固）：
/// - 内存层 NSCache（条数上限 200）+ 磁盘层 URLCache（20MB，LRU 自动淘汰）；
/// - **P2-1：会话挂与主 API 会话相同的 PinningURLSessionDelegate**——
///   锚点证书（27 张 PEM，锚点∪系统加法配置）+ 域名白名单 fail-closed，
///   封面流量不再绕过证书校验链路（原独立普通会话只有系统信任）；
/// - **P2-3：请求前经 SourceRegistry.imageRefererFor 查防盗链 Referer**，
///   guoguo.org.cn 等图源封面不再 403 空白；
/// - 未引入任何第三方库。
final class CoverImageCache: @unchecked Sendable {
    static let shared = CoverImageCache()

    /// 内部会话（internal：单测断言其 delegate 为 PinningURLSessionDelegate）。
    let session: URLSession
    private let memory = NSCache<NSURL, UIImage>()

    private init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 512 * 1024,
            diskCapacity: 20 * 1024 * 1024,
            diskPath: "CoverImages"
        )
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"]
        // P2-1：同一套证书锚点 + 域名白名单 delegate（封面域名均在白名单内：
        // tingyou.fm / tingyou8.vip / kuwo.cn / guoguo.org.cn 为后缀域，
        // shuyinfm OSS / imge.kugou.com 为精确域）
        session = URLSession(configuration: config, delegate: PinningURLSessionDelegate(), delegateQueue: nil)
        memory.countLimit = 200
    }

    /// P2-3：构建封面请求——防盗链图源（guoguo.org.cn 等）带 Referer。
    static func makeRequest(for url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if let host = url.host, let referer = SourceRegistry.imageRefererFor(host: host) {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return req
    }

    /// 取图：内存 → URLCache（含磁盘）→ 网络；磁盘命中对调用方透明。
    func image(for url: URL) async -> UIImage? {
        if let cached = memory.object(forKey: url as NSURL) {
            return cached
        }
        let response: URLResponse?
        let data: Data?
        do {
            (data, response) = try await session.data(for: Self.makeRequest(for: url))
        } catch {
            return nil // 含白名单拒绝 / TLS 失败，静默回落占位图
        }
        guard let resp = response,
              let mimeType = resp.mimeType, mimeType.hasPrefix("image/"),
              let img = data.flatMap(UIImage.init(data:)) else {
            return nil
        }
        memory.setObject(img, forKey: url as NSURL)
        return img
    }

    /// 清空缓存（设置页预留入口，当前版本未接 UI）。
    func clearAll() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }
}
