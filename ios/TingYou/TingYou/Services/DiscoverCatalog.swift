import Foundation

/// build 21 · 反馈 4/6（增强 2/3）：发现页按原始音源拉取分类。
/// 不再硬套 tingyou 的 6 个 section——每个源用自己的原始分类结构：
/// - tingyou：rank API 的 5 个 section（recommend/new/hot/serial/story）；
/// - ting15 / ting08：站点首页导航的一级分类页（/<分类>/index1.html，实测可达，
///   分类页 DOM 与搜索结果页同模板，条目形态 /<分类>/<id>.html 直接复用 parseSearch）；
/// - mekui：移动站为 Next.js SPA、无 SSR 分类数据，且无公开榜单 API（实测 /api/list/* 404）→ 不支持；
/// - ytysxs：全站有人机验证门（实测 /?s= 稳定返回「搜索驗證」页）→ 不支持。
struct DiscoverCategory: Sendable, Identifiable, Equatable {
    /// 分类 id（tingyou section 名 / HTML 源分类路径段）
    let id: String
    /// 显示名（站点原始名称）
    let name: String
}

enum DiscoverCatalog {
    /// 发现页可选音源（含不支持源——UI 如实标注，不硬造数据）
    static let sourceOptions: [(id: String, name: String)] = [
        (SourceRegistry.TINGYOU, "听友FM"),
        (SourceRegistry.TING15, "听十五"),
        (SourceRegistry.TING08, "听吧"),
        (SourceRegistry.YTYXSX, "悦听有声书"),
        (SourceRegistry.MEKUI, "书音FM"),
    ]

    /// 不支持发现页的源（UI 显示提示而非空列表）
    static let unsupportedSources: Set<String> = [
        SourceRegistry.YTYXSX, // 人机验证门，发现数据无法稳定获取
        SourceRegistry.MEKUI,  // SPA 无 SSR 分类数据、无榜单 API
    ]

    /// 各源的原始分类清单（顺序 = 站点导航顺序）
    static func categories(for src: String) -> [DiscoverCategory] {
        switch src {
        case SourceRegistry.TINGYOU:
            return [
                DiscoverCategory(id: "recommend", name: "推荐"),
                DiscoverCategory(id: "new", name: "最新"),
                DiscoverCategory(id: "hot", name: "热门"),
                DiscoverCategory(id: "serial", name: "连载"),
                DiscoverCategory(id: "story", name: "评书"),
            ]
        case SourceRegistry.TING15:
            // m.ting15.com 首页导航（2026-10-20 实测）
            return [
                DiscoverCategory(id: "wuxiaxuanhuan", name: "武侠玄幻"),
                DiscoverCategory(id: "kongbulingyi", name: "恐怖灵异"),
                DiscoverCategory(id: "tuilixuanyi", name: "推理悬疑"),
                DiscoverCategory(id: "dushiyanqing", name: "都市言情"),
                DiscoverCategory(id: "jiatinglunli", name: "家庭伦理"),
                DiscoverCategory(id: "wenxuemingzhu", name: "官场职场"),
                DiscoverCategory(id: "jingdianpingshu", name: "经典评书"),
                DiscoverCategory(id: "quyixiqu", name: "曲艺戏曲"),
                DiscoverCategory(id: "xiangshengxiaopin", name: "相声小品"),
                DiscoverCategory(id: "yinyue", name: "助眠音频"),
            ]
        case SourceRegistry.TING08:
            // www.ting08.com 首页导航（2026-10-20 实测）
            return [
                DiscoverCategory(id: "wuxia", name: "武侠"),
                DiscoverCategory(id: "yanqing", name: "言情"),
                DiscoverCategory(id: "tuili", name: "推理"),
                DiscoverCategory(id: "xunhuan", name: "玄幻"),
                DiscoverCategory(id: "lingyi", name: "灵异"),
                DiscoverCategory(id: "lishi", name: "历史"),
                DiscoverCategory(id: "guanc", name: "官场"),
                DiscoverCategory(id: "junlv", name: "军旅"),
                DiscoverCategory(id: "zhic", name: "职场"),
                DiscoverCategory(id: "xuanyi", name: "悬疑"),
                DiscoverCategory(id: "chuanyue", name: "穿越"),
                DiscoverCategory(id: "xiaopin", name: "小品"),
                DiscoverCategory(id: "pingshu", name: "评书"),
                DiscoverCategory(id: "xiqu", name: "戏曲"),
                DiscoverCategory(id: "cyy", name: "助眠音乐"),
            ]
        default:
            return []
        }
    }

    /// HTML 源分类页 URL（第 page 页，1 基）。
    /// ting15/ting08 分页形态：/<分类>/index2.html（实测）。
    static func categoryPageURL(cfg: SourceRegistry.MsrcSourceConfig, categoryId: String, page: Int) -> String? {
        guard categoryId.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil else { return nil }
        guard cfg.id == SourceRegistry.TING15 || cfg.id == SourceRegistry.TING08 else { return nil }
        return "\(cfg.siteBase)/\(categoryId)/index\(max(1, page)).html"
    }
}
