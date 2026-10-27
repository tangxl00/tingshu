import Foundation

/// build 21 · 反馈 4/6（增强 2/3）：发现页按原始音源拉取分类。
/// 不再硬套 tingyou 的 6 个 section——每个源用自己的原始分类结构：
/// - tingyou：rank API 的 5 个 section（recommend/new/hot/serial/story）；
/// build 37 · 反馈 1：听十五（ting15）/ 书音FM（mekui）下架——可选音源与
/// 分类清单摘除（同 build 36 删听吧 ting08 的模式）。
/// build 45 · 反馈 3：悦听（ytysxs）全链摘除——可选音源/不支持集一并删除
///（悦听发现页本来就不支持，删除后 sourceOptions 只剩实测可用的源）。
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
        (SourceRegistry.BILI, "B站"),
    ]

    /// 不支持发现页的源（UI 显示提示而非空列表）
    static let unsupportedSources: Set<String> = []

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
        case SourceRegistry.BILI:
            // v1.4.1 · B站 6 个分类（BiliCategories.ALL：关键词搜索口径，数据走
            // SourceRouter.discoverCategory 的 BILI case）
            return BiliCategories.ALL.map { DiscoverCategory(id: $0.key, name: $0.name) }
        default:
            return []
        }
    }

    /// HTML 源分类页 URL（第 page 页，1 基）。
    /// ting15 分页形态：/<分类>/index2.html（实测）。
    /// build 37 · 反馈 1：ting15 已下架（SourceRegistry 常量删除）；本函数保留供
    /// MsrcAdapter 编译（解析器与离线测试按 build 36 删 ting08 的同一模式保留），
    /// id 比较改为字面量，语义不变——已下架源永远走不进来。
    static func categoryPageURL(cfg: SourceRegistry.MsrcSourceConfig, categoryId: String, page: Int) -> String? {
        guard categoryId.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil else { return nil }
        guard cfg.id == "ting15" else { return nil }
        return "\(cfg.siteBase)/\(categoryId)/index\(max(1, page)).html"
    }
}
