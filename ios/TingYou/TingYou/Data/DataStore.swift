import Foundation

final class ThemeStore {
    static let MODE_LIGHT = 0
    static let MODE_DARK = 1
    static let MODE_FOLLOW_SYSTEM = 2

    var themeMode: Int {
        get { UserDefaults.standard.integer(forKey: "theme_mode") }
        set { UserDefaults.standard.set(newValue, forKey: "theme_mode") }
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

    func intro(for src: String, albumId: Int64) -> Int {
        UserDefaults.standard.integer(forKey: "\(kIntro)\(src)_\(albumId)")
    }
    func setIntro(_ sec: Int, src: String, albumId: Int64) {
        UserDefaults.standard.set(sec, forKey: "\(kIntro)\(src)_\(albumId)")
    }
    func outro(for src: String, albumId: Int64) -> Int {
        UserDefaults.standard.integer(forKey: "\(kOutro)\(src)_\(albumId)")
    }
    func setOutro(_ sec: Int, src: String, albumId: Int64) {
        UserDefaults.standard.set(sec, forKey: "\(kOutro)\(src)_\(albumId)")
    }
}

final class SourceEnabledStore {
    private let kPrefix = "source_enabled_"

    func isEnabled(_ src: String) -> Bool {
        UserDefaults.standard.object(forKey: "\(kPrefix)\(src)") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "\(kPrefix)\(src)")
    }
    func setEnabled(_ src: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "\(kPrefix)\(src)")
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
