import Foundation
import Observation
import SwiftUI

/// 外观模式唯一数据源。
/// 修复（Bug 3）：原实现是普通类 + MineScreen 里另有一份 @AppStorage("theme_mode") 双入口，
/// 且全工程无任何 .preferredColorScheme 消费——设置只存不用，切换外观无效果。
/// 现改为 @Observable，UI 在根视图读取 themeMode 驱动 .preferredColorScheme，切换即时生效。
@Observable
@MainActor
final class ThemeStore {
    static let MODE_LIGHT = 0
    static let MODE_DARK = 1
    static let MODE_FOLLOW_SYSTEM = 2

    static let storageKey = "theme_mode"

    private let defaults: UserDefaults

    /// 当前模式（0 浅色 / 1 深色 / 2 跟随系统）
    var themeMode: Int {
        didSet {
            guard oldValue != themeMode else { return }
            defaults.set(themeMode, forKey: Self.storageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 未设置时默认跟随系统（与原 @AppStorage 默认值 2 一致）
        themeMode = defaults.object(forKey: Self.storageKey) == nil
            ? Self.MODE_FOLLOW_SYSTEM
            : defaults.integer(forKey: Self.storageKey)
    }

    func setMode(_ mode: Int) {
        themeMode = min(max(mode, Self.MODE_LIGHT), Self.MODE_FOLLOW_SYSTEM)
    }

    /// 0/1/2 → ColorScheme 映射（nil = 跟随系统）；纯函数，根视图与单测共用
    static func colorScheme(for mode: Int) -> ColorScheme? {
        switch mode {
        case MODE_LIGHT: return .light
        case MODE_DARK: return .dark
        default: return nil
        }
    }
}

final class ListeningTimeStore {
    private let kTotal = "listening_total_ms"
    private let kToday = "listening_today_ms"
    private let kDay = "listening_day"

    var totalMs: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: kTotal)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: kTotal) }
    }

    var todayMs: Int64 {
        get {
            let storedDay = UserDefaults.standard.string(forKey: kDay) ?? ""
            let today = Self.todayKey()
            if storedDay != today {
                UserDefaults.standard.set(today, forKey: kDay)
                UserDefaults.standard.set(0, forKey: kToday)
                return 0
            }
            return Int64(UserDefaults.standard.integer(forKey: kToday))
        }
        set {
            UserDefaults.standard.set(Self.todayKey(), forKey: kDay)
            UserDefaults.standard.set(Int(newValue), forKey: kToday)
        }
    }

    static func todayKey() -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    func addSession(_ ms: Int64) {
        totalMs += ms
        todayMs += ms
    }
}

final class SkipSettingsStore {
    private let kIntro = "skip_intro_"
    private let kOutro = "skip_outro_"
    /// build 25：defaults 可注入（单测用 UserDefaults(suiteName:) 隔离，不污染真实跳过设置）。
    private let defaults: UserDefaults

    /// 对齐安卓 SkipSettingsStore.MAX_SECONDS：最多跳过 10 分钟。
    static let maxSeconds = 600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func intro(for src: String, albumId: Int64) -> Int {
        defaults.integer(forKey: "\(kIntro)\(src)_\(albumId)")
    }
    func setIntro(_ sec: Int, src: String, albumId: Int64) {
        defaults.set(min(max(sec, 0), Self.maxSeconds), forKey: "\(kIntro)\(src)_\(albumId)")
    }
    func outro(for src: String, albumId: Int64) -> Int {
        defaults.integer(forKey: "\(kOutro)\(src)_\(albumId)")
    }
    func setOutro(_ sec: Int, src: String, albumId: Int64) {
        defaults.set(min(max(sec, 0), Self.maxSeconds), forKey: "\(kOutro)\(src)_\(albumId)")
    }
}

final class SourceEnabledStore {
    private let kPrefix = "source_enabled_"
    /// build 22：defaults 可注入（单测用 UserDefaults(suiteName:) 隔离，不污染真实开关状态）
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// build 22 · 对齐安卓 SEARCH_SOURCES：参与搜索聚合的音源（固定顺序）。
    /// 「导入」（IMPORT）不在其列——不参与搜索聚合。
    /// build 37 · 反馈 1：听十五（ting15）/ 书音FM（mekui）下架，6 → 4 源。
    /// build 38 · 反馈 1：59听书网（ting59）下架，4 → 3 源。
    /// build 45 · 反馈 3：悦听有声书（ytysxs）下架（用户点名），3 → 2 源。
    /// build 50 · 任务 2（音源对齐 PC）：补入易听书（yitingshu），2 → 3 源
    ///（与 PC 端 v1.1.13 音源清单对齐：tingyou / bili / yitingshu）。
    static let searchSources: [String] = [
        SourceRegistry.TINGYOU,
        SourceRegistry.BILI,
        SourceRegistry.YITINGSHU,
    ]

    func isEnabled(_ src: String) -> Bool {
        defaults.object(forKey: "\(kPrefix)\(src)") == nil
            ? true
            : defaults.bool(forKey: "\(kPrefix)\(src)")
    }
    func setEnabled(_ src: String, _ enabled: Bool) {
        defaults.set(enabled, forKey: "\(kPrefix)\(src)")
    }

    /// 参与搜索聚合的启用音源（按 searchSources 固定顺序，过滤启用集）。
    func enabledSearchSources() -> [String] {
        Self.searchSources.filter { isEnabled($0) }
    }

    /// build 22 · 对齐安卓 toggleSource：带「至少保留一个」保护的定向设置。
    /// 关闭最后一个启用的搜索源时拒绝（返回 false，状态不变）；「导入」不受此保护。
    @discardableResult
    func setEnabledGuarded(_ src: String, _ enabled: Bool) -> Bool {
        if !enabled && Self.searchSources.contains(src) {
            let otherEnabled = Self.searchSources.contains { $0 != src && isEnabled($0) }
            if !otherEnabled { return false } // 最后一个启用源，禁止关闭
        }
        setEnabled(src, enabled)
        return true
    }

    /// 翻转语义的切换（对齐安卓 toggleSource 按钮行为）。
    @discardableResult
    func toggleSource(_ src: String) -> Bool {
        setEnabledGuarded(src, !isEnabled(src))
    }
}

final class ShelfLayoutStore {
    static let LAYOUT_LIST = 0
    static let LAYOUT_GRID = 1

    var layout: Int {
        get { max(0, min(1, UserDefaults.standard.integer(forKey: "shelf_layout"))) }
        set { UserDefaults.standard.set(newValue, forKey: "shelf_layout") }
    }
}
