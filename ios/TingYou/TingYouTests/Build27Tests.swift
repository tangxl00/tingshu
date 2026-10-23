import XCTest
import AVFoundation
@testable import TingYou

/// build 27：倍速间歇性失效加固 + 搜索历史「提交即记录」语义锁定。
final class Build27Tests: XCTestCase {

    // MARK: - 音频会话中断结束 → 重放速率（applyRate 加固的决策纯函数）

    /// 中断结束 + 系统建议恢复 → 应重放（来电结束等场景，AVPlayer 可能已把速率重置回默认）。
    func testInterruptionEndedWithResumeOptionReplaysRate() {
        let ended = AVAudioSession.InterruptionType.ended.rawValue
        let resume = Int(AVAudioSession.InterruptionOptions.shouldResume.rawValue)
        XCTAssertTrue(PlaybackManager.shouldResumeAfterInterruption(typeRaw: ended, optionsRaw: resume))
    }

    /// 中断开始（来电进来）→ 不重放（此时恢复会打断通话）。
    func testInterruptionBeganDoesNotReplay() {
        let began = AVAudioSession.InterruptionType.began.rawValue
        let resume = Int(AVAudioSession.InterruptionOptions.shouldResume.rawValue)
        XCTAssertFalse(PlaybackManager.shouldResumeAfterInterruption(typeRaw: began, optionsRaw: resume))
    }

    /// 中断结束但系统不建议恢复（其他 App 抢占音频后退出等）→ 不重放。
    func testInterruptionEndedWithoutResumeOptionDoesNotReplay() {
        let ended = AVAudioSession.InterruptionType.ended.rawValue
        XCTAssertFalse(PlaybackManager.shouldResumeAfterInterruption(typeRaw: ended, optionsRaw: 0))
    }

    // MARK: - 搜索历史「提交即记录」（不依赖结果成败）

    /// build 27：被反爬拦截或全源失败的搜索词同样落库——Store 层语义本就支持
    /// （add 不看结果），锁定「非空即记」判别：失败词、被拦截词与普通词一视同仁。
    func testSearchHistoryRecordsFailedOrBlockedKeywordsSameAsSuccessful() {
        let defaults = UserDefaults(suiteName: "Build27Tests-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "") }
        let store = SearchHistoryStore(defaults: defaults, key: "search_history_27")

        // 三个词模拟三种命运：成功 / 被反爬拦截（antibot）/ 全源失败——
        // UI 层（DiscoverScreen/SearchScreen build 27）已在提交时统一 add，不看结果。
        store.add("一听就上瘾的大宋史") // 录屏中被反爬拦截的词——必须可复搜
        store.add("全源失败词")
        store.add("正常成功词")

        XCTAssertEqual(store.all, ["正常成功词", "全源失败词", "一听就上瘾的大宋史"],
                       "提交即记录：三种结果成败的词一视同仁入列")
    }
}
