import Foundation

enum SourceRegistry {
    static let TINGYOU = "tingyou"
    static let BILI = "bili"
    static let YITINGSHU = "yitingshu"
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
    /// build 38 · 反馈 1：59听书网（ting59）下架（第 4 次，同一模式）——
    /// Ting59Adapter/解析器/导入页整体删除，常量摘除。
    /// build 45 · 反馈 3：悦听有声书（ytysxs）下架（第 5 次同类下架）——
    /// 常量摘除、YtysxsAdapter/VerifyWebView/VerifySheetState/KeychainTokenStore
    /// 全链删除；存量书架 ytysxs 来源的书保留（数据不删），播放/详情按
    /// 字符串兼容报「源已下架」。
    /// MsrcSourceConfig 结构、MsrcAdapter / MekuiAdapter 解析器与离线解析测试保留，
    /// isKnown / configOf / imageRefererFor 对已下架源自然返回 false / nil / nil。
    ///
    /// build 50 · 任务 2（音源对齐 PC）：PC 端 v1.1.13 当前音源清单为
    /// 听友FM（tingyou）/ B站（bili）/ 易听书（yitingshu）三个，iOS 端此前只有
    /// 前两个（缺 yitingshu）。本次补入 yitingshu——字段逐条取自 PC 端
    /// server.js 的 MSRC_SOURCES.yitingshu（id/name/siteBase/referer/kind/
    /// fetchHosts/imgHosts/audioExact/audioSuffix），不做任何新增或改写。
    static let msrcSources: [String: MsrcSourceConfig] = [
        // 易听书（stui 模板站）：详情 /tingshu/{id}.html、分类 /yi/{cat}-{page}.html、
        // 播放 /play/{bookId}-0-{idx0}.html 内联 var now 直链（单步，非两步 token）。
        // 站点 search.php 全路由被 vdimgck「系统安全验证」gate 拦截 → 搜索走本地
        // 标题索引兜底（Resources/yts_index.txt，与 PC 端同一份 16,671 条快照）。
        YITINGSHU: MsrcSourceConfig(
            id: "yitingshu",
            name: "易听书",
            siteBase: "https://www.yitingshu.com",
            referer: "https://www.yitingshu.com/",
            searchPOST: false,
            extraLHeader: false,
            searchStart: "",
            searchEnd: "",
            fetchHosts: ["www.yitingshu.com"],
            imgHosts: ["imagev2.xmcdn.com"],
            // PC 端实测 15/15 直链落在 aod.cos.tx.xmcdn.com；后缀 .xmcdn.com 会
            // 放行 imagev2 等其他子域，故按精确主机放行（与 PC v1.1.8 返修 P2-1 同口径）。
            audioExact: ["aod.cos.tx.xmcdn.com"],
            audioSuffixes: []
        )
    ]

    static func displayName(src: String) -> String {
        switch src {
        case TINGYOU: return "听友FM"
        case IMPORT: return "导入"
        case BILI: return "B站"
        default: return msrcSources[src]?.name ?? src
        }
    }

    static func isKnown(src: String) -> Bool {
        src == TINGYOU || msrcSources[src] != nil || src == BILI
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
