import Foundation

enum SleepTimerMode: Int, Sendable {
    case off = 0
    case endOfChapter = 1
    case countdown = 2
    case scheduledTime = 3
}

struct SleepTimerConfig: Sendable {
    var mode: SleepTimerMode = .off
    var minutes: Int = 0
    var minuteOfDay: Int = 0
}

struct PlaybackState: Sendable {
    var isPlaying: Bool = false
    var currentChapterIdx: Int = 0
    var currentPositionMs: Int64 = 0
    var durationMs: Int64 = 0
    var speed: Float = 1.0
    var album: Album?
    var chapterTitle: String = ""
}

struct SkipSettings: Sendable {
    var introSeconds: Int = 0
    var outroSeconds: Int = 0
}

/// build 21 · 反馈 1（播放器设置弹窗）：播放模式。
/// 顺序播放（到尾即停，与旧行为一致）/ 单曲循环（本章播完重播本章）/ 列表循环（尾章播完回第一章）。
enum PlayMode: Int, Sendable, CaseIterable, Identifiable {
    case sequence = 0
    case repeatOne = 1
    case repeatAll = 2

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .sequence: return "顺序播放"
        case .repeatOne: return "单曲循环"
        case .repeatAll: return "列表循环"
        }
    }

    var symbolName: String {
        switch self {
        case .sequence: return "arrow.right"
        case .repeatOne: return "repeat.1"
        case .repeatAll: return "repeat"
        }
    }
}
