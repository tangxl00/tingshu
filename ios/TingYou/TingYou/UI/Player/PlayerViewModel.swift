import Foundation
import SwiftData

@Observable
final class PlayerViewModel {
    var isPlaying = false
    var currentPositionMs: Int64 = 0
    var durationMs: Int64 = 0
    var speed: Float = 1.0
    var albumTitle = ""
    var chapterTitle = ""
    var coverUrl: String? = nil
    var chapters: [Chapter] = []
    var currentChapterIdx = 0
    var isFavorite = false
    var showSpeedSheet = false
    var showChapters = false
    var showSleepTimer = false
    var showSettings = false

    private var manager: PlaybackManager?

    func bind(manager: PlaybackManager) {
        self.manager = manager
        self.isPlaying = manager.isPlaying
        self.currentPositionMs = manager.currentPositionMs
        self.durationMs = manager.durationMs
        self.speed = manager.speed
        self.albumTitle = manager.currentAlbumTitle
        self.chapterTitle = manager.currentChapterTitle
        self.coverUrl = manager.coverUrl
    }

    func togglePlay() {
        manager?.togglePlayPause()
        isPlaying = manager?.isPlaying ?? false
    }

    func next() {
        manager?.nextChapter()
        sync()
    }

    func previous() {
        manager?.previousChapter()
        sync()
    }

    func seekTo(pct: Double) {
        let pos = Int64(Double(durationMs) * pct)
        manager?.seek(to: pos)
        currentPositionMs = pos
    }

    func seekRelative(_ ms: Int64) {
        manager?.seekRelative(ms)
        currentPositionMs = manager?.currentPositionMs ?? currentPositionMs
    }

    func setSpeed(_ s: Float) {
        manager?.speed = s
        speed = s
    }

    func playChapter(index: Int) {
        guard index < chapters.count else { return }
        // manager would need to support indexed chapter jumping
    }

    func toggleFavorite() {
        isFavorite.toggle()
    }

    private func sync() {
        guard let m = manager else { return }
        isPlaying = m.isPlaying
        currentPositionMs = m.currentPositionMs
        durationMs = m.durationMs
        albumTitle = m.currentAlbumTitle
        chapterTitle = m.currentChapterTitle
        coverUrl = m.coverUrl
    }
}
