import Foundation

// MARK: - 59听书网分类模型
// v1.4.1：自 UI/Ting59/Ting59HomeScreen.swift 迁出（该文件已删除）——
// 发现页浏览区音源选择器需要读取 59听书网 的原始分类清单，
// TingYouTests/Ting59StructuralTests 亦按 Ting59Categories.ALL 断言。

struct Ting59Category: Identifiable, Sendable {
    let id: String
    let name: String
}

enum Ting59Categories {
    static let ALL: [Ting59Category] = [
        Ting59Category(id: "xuanhuan", name: "玄幻"),
        Ting59Category(id: "wuxia", name: "武侠"),
        Ting59Category(id: "dushi", name: "都市"),
        Ting59Category(id: "yanqing", name: "言情"),
        Ting59Category(id: "chuanyue", name: "穿越"),
        Ting59Category(id: "kongbu", name: "恐怖"),
        Ting59Category(id: "lishi", name: "历史"),
        Ting59Category(id: "youxi", name: "网游"),
        Ting59Category(id: "lingyi", name: "灵异"),
        Ting59Category(id: "zhentan", name: "侦探"),
        Ting59Category(id: "jingji", name: "军事"),
        Ting59Category(id: "xianxia", name: "仙侠"),
        Ting59Category(id: "qihuan", name: "奇幻"),
        Ting59Category(id: "keji", name: "科技"),
        Ting59Category(id: "jingji2", name: "经济"),
        Ting59Category(id: "jiaoyu", name: "教育"),
        Ting59Category(id: "ertong", name: "儿童"),
        Ting59Category(id: "jiankang", name: "健康"),
        Ting59Category(id: "shenghuo", name: "生活"),
        Ting59Category(id: "yuyan", name: "语言"),
        Ting59Category(id: "zhexue", name: "哲学"),
        Ting59Category(id: "zongjiao", name: "宗教"),
        Ting59Category(id: "falv", name: "法律"),
        Ting59Category(id: "zonghe", name: "综合"),
    ]
}
