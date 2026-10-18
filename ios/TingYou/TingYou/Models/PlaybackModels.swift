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
