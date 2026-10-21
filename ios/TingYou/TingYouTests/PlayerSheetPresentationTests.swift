import XCTest
@testable import TingYou

/// build 23 · 播放器弹窗呈现机制重构的回归测试。
///
/// 真机反馈：build 22 倍速仍点不动——根因是 PlayerScreen 同一视图链挂了四个
/// `.sheet(isPresented:)`（SwiftUI 已知限制：只有最后挂载的可靠生效），不是值回写问题
/// （build 22 的 SpeedSheet.select 双保险修复是对的，但弹窗根本没弹出来）。
/// 修复：合并为单枚举驱动的 `.sheet(item:)`。
///
/// 本文件测枚举契约中**可静态验证**的部分：`sheet(item:)` 的呈现触发依赖
/// `Identifiable.id` 变化与 `Equatable` 判等。运行时呈现行为以真机 / CI 为准，
/// 不硬凑 UI 层测试（多 sheet 冲突本身就是静态审查发现不了的运行时行为）。
final class PlayerSheetPresentationTests: XCTestCase {

    /// switch 映射槽位——编译器保证穷尽，测试锁定四 case 各占唯一槽位。
    private func slot(_ s: PlayerSheet) -> Int {
        switch s {
        case .speed: 1
        case .chapters: 2
        case .sleepTimer: 3
        case .settings: 4
        }
    }

    // MARK: - Identifiable 契约（sheet(item:) 呈现触发依赖）

    func testPlayerSheetIdReturnsSelf() {
        // id = Self 写法：id 与 case 一一对应，identity 稳定
        XCTAssertEqual(PlayerSheet.speed.id, .speed)
        XCTAssertEqual(PlayerSheet.chapters.id, .chapters)
        XCTAssertEqual(PlayerSheet.sleepTimer.id, .sleepTimer)
        XCTAssertEqual(PlayerSheet.settings.id, .settings)
    }

    func testPlayerSheetIdsAreMutuallyDistinct() {
        // 四个 case 的 id 互异——sheet(item:) 靠 id 变化触发新呈现，
        // 若两个 case 的 id 相同则从 A 切到 B 不会重新呈现（这正是本次修复要杜绝的）
        let all: [PlayerSheet] = [.speed, .chapters, .sleepTimer, .settings]
        XCTAssertEqual(Set(all.map { "\($0.id)" }).count, 4, "四个弹窗 case 的 id 必须互异")
        XCTAssertEqual(all.map(slot), [1, 2, 3, 4], "四 case 各占唯一 switch 槽位，不新增不遗漏")
    }

    // MARK: - Equatable 契约（activeSheet 状态切换依赖）

    func testPlayerSheetEqualitySemantics() {
        // 同 case 相等（nil → case 触发呈现；case → nil 关闭）
        XCTAssertEqual(PlayerSheet.speed, .speed)
        XCTAssertEqual(PlayerSheet.chapters, .chapters)
        XCTAssertEqual(PlayerSheet.sleepTimer, .sleepTimer)
        XCTAssertEqual(PlayerSheet.settings, .settings)
        // 不同 case 不等（A 呈现中切 B：item 变化触发重呈现）
        XCTAssertNotEqual(PlayerSheet.speed, .settings)
        XCTAssertNotEqual(PlayerSheet.chapters, .sleepTimer)
        XCTAssertNotEqual(PlayerSheet.sleepTimer, .speed)
    }
}
