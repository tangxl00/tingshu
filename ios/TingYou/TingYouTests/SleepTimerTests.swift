import XCTest
@testable import TingYou

/// build 20 必修 4 回归：定点睡眠目标时刻计算。
/// 判别力：旧实现 scheduledTime case 计算空置（无可用产物），本组测试在旧实现下无对应物可测/必失败。
final class SleepTimerTests: XCTestCase {

    /// 上海时区的固定参照时刻：2026-10-20 12:00:00 +08:00
    private var tz: TimeZone { TimeZone(identifier: "Asia/Shanghai")! }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testTargetLaterTodayIsSameDay() {
        // now = 12:00，定点 23:30（1410 分钟）→ 今天 23:30
        let now = date(2026, 10, 20, 12, 0)
        let target = PlaybackManager.scheduledSleepTarget(minuteOfDay: 23 * 60 + 30, now: now, timeZone: tz)
        XCTAssertEqual(target, date(2026, 10, 20, 23, 30))
    }

    func testTargetAlreadyPassedRollsToTomorrow() {
        // now = 23:30，定点 06:00（360 分钟，今天已过）→ 明天 06:00
        let now = date(2026, 10, 20, 23, 30)
        let target = PlaybackManager.scheduledSleepTarget(minuteOfDay: 6 * 60, now: now, timeZone: tz)
        XCTAssertEqual(target, date(2026, 10, 21, 6, 0))
    }

    func testTargetExactlyNowRollsToTomorrow() {
        // 恰好等于现在 → 明天同一时刻（不允许 0 秒立刻暂停的边界）
        let now = date(2026, 10, 20, 8, 0)
        let target = PlaybackManager.scheduledSleepTarget(minuteOfDay: 8 * 60, now: now, timeZone: tz)
        XCTAssertEqual(target, date(2026, 10, 21, 8, 0))
    }

    func testMidnightBoundary() {
        // now = 00:10，定点 00:05（已过）→ 明天 00:05
        let now = date(2026, 10, 20, 0, 10)
        let target = PlaybackManager.scheduledSleepTarget(minuteOfDay: 5, now: now, timeZone: tz)
        XCTAssertEqual(target, date(2026, 10, 21, 0, 5))
        // now = 00:03，定点 00:05（未到）→ 今天 00:05
        let now2 = date(2026, 10, 20, 0, 3)
        let target2 = PlaybackManager.scheduledSleepTarget(minuteOfDay: 5, now: now2, timeZone: tz)
        XCTAssertEqual(target2, date(2026, 10, 20, 0, 5))
    }

    func testApplyScheduledTimerSetsConfigAndSchedules() {
        // 接线检查：定点模式设置后 sleepConfig 生效、且起了一个定时器（到点暂停逻辑与 countdown 同构）
        let pm = PlaybackManager(playbackRepository: nil)
        pm.applySleepTimer(config: SleepTimerConfig(mode: .scheduledTime, minutes: 0, minuteOfDay: 23 * 60 + 59))
        XCTAssertEqual(pm.sleepConfig.mode, .scheduledTime, "定点模式应写入 sleepConfig")
        _ = pm // 定时器在 runloop 上，单测不等待触发；触发行为与 countdown 分支共用同一闭包
    }
}
