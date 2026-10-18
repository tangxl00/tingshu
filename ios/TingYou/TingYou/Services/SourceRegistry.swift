import Foundation

enum SourceRegistry {
    static let TINGYOU = "tingyou"
    static let TING15 = "ting15"
    static let TING08 = "ting08"
    static let YTYXSX = "ytysxs"
    static let MEKUI = "mekui"
    static let IMPORT = "import"

    struct MsrcSourceConfig: Sendable {
        let id: String
        let name: String
        let siteBase: String
        let referer: String
        let searchPOST: Bool
        let extraLHeader: Bool
        let fetchHosts: [String]
        let imgHosts: [String]
        let audioExact: [String]
        let audioSuffixes: [String]
    }

    static let ting15 = MsrcSourceConfig(
        id: "ting15", name: "听十五",
        siteBase: "https://m.ting15.com", referer: "https://m.ting15.com/",
        searchPOST: false, extraLHeader: false,
        fetchHosts: ["m.ting15.com"],
        imgHosts: ["img-book-oss.guoguo.org.cn", "img-south-oss.guoguo.org.cn"],
        audioExact: ["oss-links.guoguo.org.cn", "cloud.guoguo.org.cn"],
        audioSuffixes: [".guoguo.org.cn"]
    )

    static let ting08 = MsrcSourceConfig(
        id: "ting08", name: "听吧",
        siteBase: "https://www.ting08.com", referer: "https://www.ting08.com/",
        searchPOST: true, extraLHeader: true,
        fetchHosts: ["www.ting08.com"],
        imgHosts: ["img-book-oss.guoguo.org.cn", "img-south-oss.guoguo.org.cn"],
        audioExact: ["oss-links.guoguo.org.cn", "cloud.guoguo.org.cn"],
        audioSuffixes: [".guoguo.org.cn"]
    )

    static let mekui = MsrcSourceConfig(
        id: "mekui", name: "书音FM",
        siteBase: "https://m.mekui.com", referer: "https://m.mekui.com/",
        searchPOST: false, extraLHeader: false,
        fetchHosts: ["m.mekui.com", "api.mekui.com"],
        imgHosts: ["shuyinfm.oss-cn-hangzhou.aliyuncs.com", "img1.kuwo.cn", "img2.kuwo.cn", "img3.kuwo.cn", "img4.kuwo.cn", "imge.kugou.com"],
        audioExact: ["api.aikeu.com", "mp3.aikeu.com"],
        audioSuffixes: [".aikeu.com"]
    )

    static let msrcSources: [String: MsrcSourceConfig] = [
        TING15: ting15, TING08: ting08, MEKUI: mekui
    ]

    static func displayName(src: String) -> String {
        switch src {
        case TINGYOU: return "听友FM"
        case IMPORT: return "导入"
        case YTYXSX: return "悦听有声书"
        default: return msrcSources[src]?.name ?? src
        }
    }

    static func isKnown(src: String) -> Bool {
        src == TINGYOU || msrcSources[src] != nil || src == YTYXSX
    }

    static func configOf(src: String) -> MsrcSourceConfig? { msrcSources[src] }

    static var allImgHosts: Set<String> {
        Set(msrcSources.values.flatMap { $0.imgHosts })
    }

    static func imageRefererFor(host: String) -> String? {
        msrcSources.values.first(where: { $0.imgHosts.contains(host) })?.referer
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
