import Foundation

/// build 21 · 反馈 7（增强 4）：搜索历史记忆。
/// UserDefaults 持久化；去重（已存在则移到队首）、新的置顶、上限 20 条。
/// 纯逻辑组件（defaults 可注入），可直接 XCTest。
struct SearchHistoryStore {
    static let limit = 20
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "search_history") {
        self.defaults = defaults
        self.key = key
    }

    /// 读取全部历史（队首最新）
    var all: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    var isEmpty: Bool { all.isEmpty }

    /// 提交一次搜索时即记录：去重置顶 + 截断上限。
    /// 空白词不记录。
    /// build 27：语义从「成功发起（至少一源有结果）」放宽为「提交即记」——
    /// 被悦听反爬拦截或全源失败的搜索词同样落库（用户复搜有记忆）。
    func add(_ rawKeyword: String) {
        let kw = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        var list = all
        list.removeAll { $0 == kw }
        list.insert(kw, at: 0)
        if list.count > Self.limit {
            list.removeLast(list.count - Self.limit)
        }
        defaults.set(list, forKey: key)
    }

    /// 单条删除
    func remove(_ keyword: String) {
        var list = all
        list.removeAll { $0 == keyword }
        defaults.set(list, forKey: key)
    }

    /// 一键清空
    func clear() {
        defaults.removeObject(forKey: key)
    }

    /// build 28 · 搜索历史输入联动建议：返回与 query 匹配（前缀或包含，不区分大小写）的历史词。
    func matching(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(q) }
    }
}
