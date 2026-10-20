import XCTest
import SwiftUI
@testable import TingYou

/// Bug 3 验收：主题模式映射（0/1/2 → ColorScheme）与单数据源持久化。
final class ThemeStoreTests: XCTestCase {

    /// 0/1/2 → 对应 ColorScheme；越界值防御性回落为跟随系统。
    func testColorSchemeMapping() {
        XCTAssertEqual(ThemeStore.colorScheme(for: ThemeStore.MODE_LIGHT), ColorScheme.light)
        XCTAssertEqual(ThemeStore.colorScheme(for: ThemeStore.MODE_DARK), ColorScheme.dark)
        XCTAssertNil(ThemeStore.colorScheme(for: ThemeStore.MODE_FOLLOW_SYSTEM), "跟随系统应映射为 nil")
        XCTAssertNil(ThemeStore.colorScheme(for: 99), "越界值应防御性回落为跟随系统")
    }

    @MainActor
    func testDefaultModeIsFollowSystem() throws {
        let defaults = try makeDefaults()
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.themeMode, ThemeStore.MODE_FOLLOW_SYSTEM, "未设置时应默认跟随系统")
    }

    @MainActor
    func testSetModePersistsAndClamps() throws {
        let defaults = try makeDefaults()
        let store = ThemeStore(defaults: defaults)
        store.setMode(ThemeStore.MODE_DARK)
        XCTAssertEqual(defaults.integer(forKey: ThemeStore.storageKey), ThemeStore.MODE_DARK,
                       "设置应立即落 UserDefaults（切换即生效、无需重启）")
        store.setMode(99)
        XCTAssertEqual(store.themeMode, ThemeStore.MODE_FOLLOW_SYSTEM, "越界应被钳制到 2")
        store.setMode(-5)
        XCTAssertEqual(store.themeMode, ThemeStore.MODE_LIGHT, "负值应被钳制到 0")
    }

    @MainActor
    func testModeSurvivesReload() throws {
        let defaults = try makeDefaults()
        ThemeStore(defaults: defaults).setMode(ThemeStore.MODE_LIGHT)
        let reloaded = ThemeStore(defaults: defaults)
        XCTAssertEqual(reloaded.themeMode, ThemeStore.MODE_LIGHT, "同一 defaults 重建后应读到已存值")
    }

    // MARK: - 辅助

    private func makeDefaults() throws -> UserDefaults {
        let name = "theme-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
