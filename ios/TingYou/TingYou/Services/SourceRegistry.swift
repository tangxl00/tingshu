import Foundation

enum SourceRegistry {
    static let TINGYOU = "tingyou"
    static let YTYXSX = "ytysxs"
    static let BILI = "bili"
    static let TING59 = "ting59"
    static let IMPORT = "import"

    struct MsrcSourceConfig: Sendable {
        let id: String
        let name: String
        let siteBase: String
        let referer: String
        let searchPOST: Bool
        let extraLHeader: Bool
        /// 搜索结果 HTML 切片边界（与安卓 SourceRegistry 对齐；mekui 为 JSON API，留空）
        let searchStart: String
        let searchEnd: String
        let fetchHosts: [String]
        let imgHosts: [String]
        let audioExact: [String]
        let audioSuffixes: [String]
    }

    /// build 37 · 反馈 1：听十五（ting15）/ 书音FM（mekui）已下架（同 build 36
    /// 删听吧 ting08 的模式）——常量与 config 摘除，MSRC 注册表清空。
    /// MsrcSourceConfig 结构、MsrcAdapter / MekuiAdapter 解析器与离线解析测试保留，
    /// isKnown / configOf / imageRefererFor 对已下架源自然返回 false / nil / nil。
    static let msrcSources: [String: MsrcSourceConfig] = [:]

    static func displayName(src: String) -> String {
        switch src {
        case TINGYOU: return "听友FM"
        case IMPORT: return "导入"
        case YTYXSX: return "悦听有声书"
        case BILI: return "B站"
        case TING59: return "59听书网"
        default: return msrcSources[src]?.name ?? src
        }
    }

    static func isKnown(src: String) -> Bool {
        src == TINGYOU || msrcSources[src] != nil || src == YTYXSX || src == BILI || src == TING59
    }

    static func configOf(src: String) -> MsrcSourceConfig? { msrcSources[src] }

    static var allImgHosts: Set<String> {
        Set(msrcSources.values.flatMap { $0.imgHosts })
    }

    static func imageRefererFor(host: String) -> String? {
        msrcSources.values.first(where: { $0.imgHosts.contains(host) })?.referer
    }

    /// build 20 必修 1：按确切源取封面防盗链 Referer。
    /// guoguo.org.cn 图床被 ting15 / ting08 两个源共用，旧实现按字典序取第一个源的
    /// referer，二选一不稳定；调用链带上源上下文后各自带自己的 referer。
    /// 源未知 / 该源不使用此图床时，回落到旧的按 host 全局查找（保持旧行为兜底）。
    static func imageRefererFor(host: String, source: String?) -> String? {
        if let source, let cfg = msrcSources[source], cfg.imgHosts.contains(host) {
            return cfg.referer
        }
        return imageRefererFor(host: host)
    }

    static func audioHostAllowed(cfg: MsrcSourceConfig, host: String) -> Bool {
        cfg.audioExact.contains(host) || cfg.audioSuffixes.contains(where: { host.hasSuffix($0) })
    }

    static func fetchHostAllowed(cfg: MsrcSourceConfig, host: String) -> Bool {
        cfg.fetchHosts.contains(host) || cfg.imgHosts.contains(host)
    }

    static func externalKey(src: String, albumId: Int64) -> String {
        src == TINGYOU ? String(albumId) : "\(src):\(albumId)"
    }
}
