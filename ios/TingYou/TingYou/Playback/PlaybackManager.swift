import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// Swift 6 并发装箱：跨 Task 隔离域持有 AVAssetResourceLoadingRequest。
/// AVFoundation 的 finishLoading / redirect 支持任意线程调用，此处仅解除编译器 Sendable 检查。
private struct LoadingRequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
}

@Observable
final class PlaybackManager: NSObject, @unchecked Sendable, AVAssetResourceLoaderDelegate {
    private let player = AVPlayer()
    /// 真实播放地址解析器（P0-1：占位 URI 经 AVAssetResourceLoaderDelegate 惰性解析）
    private let playbackRepository: PlaybackRepository?
    private var currentAlbum: Album?
    var currentChapters: [Chapter] = []
    private var currentChapterIdx: Int = 0
    private var loaderTasks: [Int: Task<Void, Never>] = [:]
    private var loaderTaskSeq = 0
    private var timeObserver: Any?
    private var itemObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var _speed: Float = 1.0
    private var sleepTimer: Timer?
    private var sleepConfig = SleepTimerConfig()
    private var listenStartMs: Int64 = 0
    private let listeningTimeStore = ListeningTimeStore()
    private let skipStore = SkipSettingsStore()
    private var outroSkipTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    var isPlaying: Bool = false
    var currentPositionMs: Int64 = 0
    var durationMs: Int64 = 0
    var speed: Float {
        get { _speed }
        set {
            _speed = newValue
            player.rate = newValue
            UserDefaults.standard.set(newValue, forKey: "playback_speed")
        }
    }
    var currentChapterTitle: String = ""
    var currentAlbumTitle: String = ""
    var coverUrl: String? = nil

    init(playbackRepository: PlaybackRepository? = nil) {
        self.playbackRepository = playbackRepository
        super.init()
        _speed = UserDefaults.standard.float(forKey: "playback_speed")
        if _speed < 0.5 || _speed > 4.0 { _speed = 1.0 }
        setupAudioSession()
        setupNowPlaying()
        addPeriodicTimeObserver()
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [weak self] _ in self?.onChapterFinished() }
            .store(in: &cancellables)
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("AudioSession setup error: \(error)")
        }
    }

    private func setupNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentChapterTitle
        info[MPMediaItemPropertyArtist] = currentAlbumTitle
        if let url = coverUrl, let imgURL = URL(string: url) {
            // async load handled separately
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0.0
        info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentPositionMs) / 1000.0
        center.nowPlayingInfo = info

        let cmdCenter = MPRemoteCommandCenter.shared()
        cmdCenter.playCommand.addTarget { [weak self] _ in
            self?.play(); return .success
        }
        cmdCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        cmdCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextChapter(); return .success
        }
        cmdCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousChapter(); return .success
        }
        cmdCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let ev = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: Int64(ev.positionTime * 1000))
            }
            return .success
        }
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: 1)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentPositionMs = Int64(time.seconds * 1000)
            self.updateNowPlaying()
            self.checkOutroSkip()
        }
    }

    private func updateNowPlaying() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = currentChapterTitle
        info[MPMediaItemPropertyArtist] = currentAlbumTitle
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0.0
        info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentPositionMs) / 1000.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func prepareQueue(album: Album, chapters: [Chapter], startIdx: Int, startPosMs: Int64 = 0) {
        currentAlbum = album
        currentChapters = chapters
        currentChapterIdx = max(0, chapters.firstIndex(where: { $0.index == startIdx }) ?? 0)
        currentAlbumTitle = album.title
        coverUrl = album.coverUrl
        loadCurrentChapter(startPosMs: startPosMs, autoPlay: false)
    }

    func playQueue(album: Album, chapters: [Chapter], startIdx: Int, startPosMs: Int64 = 0) {
        prepareQueue(album: album, chapters: chapters, startIdx: startIdx, startPosMs: startPosMs)
        play()
    }

    private func loadCurrentChapter(startPosMs: Int64 = 0, autoPlay: Bool = true) {
        guard currentChapterIdx < currentChapters.count else { return }
        let ch = currentChapters[currentChapterIdx]
        currentChapterTitle = ch.title
        currentChapterIdx = currentChapters.firstIndex(where: { $0.chapterId == ch.chapterId }) ?? currentChapterIdx

        // P0-1：构建占位 URI，经 AVAssetResourceLoaderDelegate 在 AVPlayer 打开资源时
        // 惰性解析为真实音频直链（对等安卓 PlayUri + PlayUrlResolver + ResolvingDataSource）
        let uri = PlayUri.build(src: currentAlbum?.source ?? "tingyou",
                                albumId: currentAlbum?.albumId ?? 0,
                                chapterIdx: ch.index)
        guard let url = URL(string: uri) else { return }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .global(qos: .userInitiated))
        let item = AVPlayerItem(asset: asset)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .readyToPlay {
                self?.durationMs = Int64(item.duration.seconds * 1000)
                self?.updateNowPlaying()
            }
        }
        player.replaceCurrentItem(with: item)
        if startPosMs > 0 {
            player.seek(to: CMTime(seconds: Double(startPosMs) / 1000.0, preferredTimescale: 1000))
        }
        if autoPlay {
            player.rate = speed
            isPlaying = true
            listenStartMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
        updateNowPlaying()
    }

    // MARK: - AVAssetResourceLoaderDelegate（P0-1 真实解析）

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              url.scheme == "tingyou-chapter",
              let parsed = PlayUri.parse(url.absoluteString) else {
            return false // 非本 scheme 的请求不拦截
        }
        let seq = loaderTaskSeq
        loaderTaskSeq += 1
        // Swift 6 并发装箱：AVAssetResourceLoadingRequest 非 Sendable，
        // 显式声明跨隔离域传递（finishLoading 允许任意线程调用，AVFoundation 线程安全）
        let box = LoadingRequestBox(request: loadingRequest)
        let task = Task { [weak self] in
            do {
                guard let repository = self?.playbackRepository else {
                    box.request.finishLoading(with: URLError(.unsupportedURL))
                    return
                }
                let playUrl = try await repository.getPlayUrl(
                    src: parsed.src, albumId: parsed.albumId, chapterIdx: parsed.chapterIdx)
                guard let redirectURL = URL(string: playUrl) else {
                    box.request.finishLoading(with: URLError(.badURL))
                    return
                }
                box.request.redirect = URLRequest(url: redirectURL)
                box.request.response = HTTPURLResponse(
                    url: redirectURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
                box.request.finishLoading()
            } catch {
                box.request.finishLoading(with: error)
            }
            self?.loaderTasks.removeValue(forKey: seq)
        }
        loaderTasks[seq] = task
        return true // 已异步接管，等待 finishLoading
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // AVPlayer 取消等待：不中断已发起的解析任务（结果幂等，finishLoading 后无效调用安全）
    }

    /// 章节列表页直接跳章（PlayerViewModel.playChapter 接线）
    func playChapter(at index: Int) {
        guard index >= 0, index < currentChapters.count else { return }
        pause()
        currentChapterIdx = index
        loadCurrentChapter(autoPlay: true)
    }

    func play() {
        guard player.currentItem != nil else { return }
        player.rate = speed
        isPlaying = true
        listenStartMs = Int64(Date().timeIntervalSince1970 * 1000)
    }

    func pause() {
        player.pause()
        isPlaying = false
        if listenStartMs > 0 {
            let elapsed = Int64(Date().timeIntervalSince1970 * 1000) - listenStartMs
            if elapsed > 0 { listeningTimeStore.addSession(elapsed) }
            listenStartMs = 0
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func nextChapter() {
        guard currentChapterIdx + 1 < currentChapters.count else { return }
        pause()
        currentChapterIdx += 1
        loadCurrentChapter(autoPlay: true)
    }

    func previousChapter() {
        guard currentChapterIdx > 0 else {
            seek(to: 0)
            return
        }
        pause()
        currentChapterIdx -= 1
        loadCurrentChapter(autoPlay: true)
    }

    func seek(to positionMs: Int64) {
        let clamped = max(0, min(positionMs, durationMs))
        player.seek(to: CMTime(seconds: Double(clamped) / 1000.0, preferredTimescale: 1000))
        currentPositionMs = clamped
        updateNowPlaying()
    }

    func seekRelative(_ deltaMs: Int64) {
        seek(to: currentPositionMs + deltaMs)
    }

    private func onChapterFinished() {
        if sleepConfig.mode == .endOfChapter {
            pause()
            sleepConfig.mode = .off
            return
        }
        nextChapter()
    }

    private func checkOutroSkip() {
        guard let album = currentAlbum else { return }
        let outro = skipStore.outro(for: album.source, albumId: album.albumId)
        guard outro > 0, durationMs > 0 else { return }
        let remaining = durationMs - currentPositionMs
        if remaining > 0 && remaining <= Int64(outro) * 1000 {
            nextChapter()
        }
    }

    func applySleepTimer(config: SleepTimerConfig) {
        sleepTimer?.invalidate()
        sleepConfig = config
        switch config.mode {
        case .off: break
        case .countdown:
            sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.minutes * 60), repeats: false) { [weak self] _ in
                self?.pause()
                self?.sleepConfig.mode = .off
            }
        case .scheduledTime:
            let now = Date()
            var cal = Calendar.current
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = config.minuteOfDay / 60
            comps.minute = config.minuteOfDay % 60
            if let target = cal.date(from: comps), target <= now {
                // next day
            }
            // simplified: use countdown approximation
        default: break
        }
    }

    func setSkipSettings(intro: Int, outro: Int, src: String, albumId: Int64) {
        skipStore.setIntro(intro, src: src, albumId: albumId)
        skipStore.setOutro(outro, src: src, albumId: albumId)
    }

    deinit {
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        pause()
    }
}
