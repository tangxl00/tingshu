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
    /// Bug 2：对外只读暴露当前专辑（收藏/历史接线用，原为 private）
    private(set) var currentAlbum: Album?
    var currentChapters: [Chapter] = []
    /// Bug 2：对外只读暴露当前章序号（章节列表当前项高亮用，避免按标题匹配）
    private(set) var currentChapterIdx: Int = 0
    private var loaderTasks: [Int: Task<Void, Never>] = [:]
    private var loaderTaskSeq = 0
    // build 19 P2-2：loaderTasks / loaderTaskSeq 被 loader 队列与 Task 闭包并发读写，
    // Dictionary 并发写是未定义行为——统一经 NSLock 保护（只动容器，不改 seq 比对语义）。
    private let loaderLock = NSLock()
    private var timeObserver: Any?
    private var itemObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var _speed: Float = 1.0
    private var sleepTimer: Timer?
    /// build 20 必修 4：定点睡眠接线单测断言用（对外只读）。
    private(set) var sleepConfig = SleepTimerConfig()
    private var listenStartMs: Int64 = 0
    private let listeningTimeStore = ListeningTimeStore()
    private let skipStore = SkipSettingsStore()
    private var outroSkipTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Bug 2 播放历史落库 + 增强 5.3 下一章预取

    /// 历史落库出口（AppContainer 注入 AlbumRepository；单测可注入假实现）
    var historyRecorder: (any PlaybackHistoryRecording)? = nil
    private static let historyThrottleMs: Int64 = 5_000
    private var lastHistoryWriteMs: Int64 = 0
    // build 19 P1-2：原实现 `Task { await recorder.recordHistory(...) }` 无序并发，
    // 快速切章时旧章节的写任务可能后到后写，历史回跳旧章。
    // 改为「串行排水 + 只保留最新」：写入任务严格串行，同一时刻只保留最新一次待写数据——
    // 旧章节数据要么被新章节数据覆盖掉（从未落库），要么先于新数据写入（最终值=新章节）。
    private struct PendingHistoryWrite: Sendable {
        let album: Album
        let chapter: Chapter
        let positionMs: Int64
        let durationMs: Int64
    }
    private var pendingHistoryWrite: PendingHistoryWrite?
    private var historyDrainTask: Task<Void, Never>?
    private let historyLock = NSLock()

    /// 下一章直链预取任务（每次换章重建）
    private var prefetchTask: Task<Void, Never>?
    /// 已解析直链缓存：占位 URI → 真实直链；resourceLoader 命中即秒回，切章零等待
    private var resolvedPlayUrls: [String: String] = [:]
    private let resolveLock = NSLock()
    private static let resolvedCacheLimit = 12

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
            self.recordHistory() // Bug 2：进度节流落库（~5s 一次）
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
        // Bug 2：起播/切章立即落一次历史（记录新章节起点）
        recordHistory(force: true, positionMs: startPosMs)
        // 增强 5.3：预取下一章直链（提前解析 + AVFoundation 预热），切章零等待
        scheduleNextChapterPrefetch()
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
        // 增强 5.3：预取命中 → 直接 redirect，省一次网络解析（切章零等待）
        if let cached = resolvedPlayUrl(forKey: url.absoluteString),
           let redirectURL = URL(string: cached) {
            loadingRequest.redirect = URLRequest(url: redirectURL)
            loadingRequest.response = HTTPURLResponse(
                url: redirectURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            loadingRequest.finishLoading()
            return true
        }
        loaderLock.lock()
        let seq = loaderTaskSeq
        loaderTaskSeq += 1
        loaderLock.unlock()
        // Swift 6 并发装箱：AVAssetResourceLoadingRequest 非 Sendable，
        // 显式声明跨隔离域传递（finishLoading 允许任意线程调用，AVFoundation 线程安全）
        let box = LoadingRequestBox(request: loadingRequest)
        let cacheKey = url.absoluteString
        let task = Task { [weak self] in
            do {
                guard let repository = self?.playbackRepository else {
                    box.request.finishLoading(with: URLError(.unsupportedURL))
                    return
                }
                let playUrl = try await repository.getPlayUrl(
                    src: parsed.src, albumId: parsed.albumId, chapterIdx: parsed.chapterIdx)
                // 解析结果顺手入缓存（同一章 seek/重开不再重复解析）
                self?.storeResolved(key: cacheKey, url: playUrl)
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
            self?.removeLoaderTask(seq)
        }
        loaderLock.lock()
        loaderTasks[seq] = task
        loaderLock.unlock()
        return true // 已异步接管，等待 finishLoading
    }

    /// build 19 P2-2：loaderTasks 字典的并发访问统一经锁收口。
    private func removeLoaderTask(_ seq: Int) {
        loaderLock.lock()
        defer { loaderLock.unlock() }
        loaderTasks.removeValue(forKey: seq)
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
        // Bug 2：暂停立即落一次历史（保住最后进度）
        recordHistory(force: true)
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

    /// build 20 必修 4：定点睡眠的目标时刻计算（抽成纯函数供单测）。
    /// minuteOfDay 为当日分钟数（0..1439）；当日时刻未到 → 今天，已到（含恰好等于现在）→ 明天同一时刻。
    /// Asia/Shanghai 与应用其余时区口径一致。
    static func scheduledSleepTarget(minuteOfDay: Int, now: Date = Date(),
                                     timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) -> Date {
        var cal = Calendar.current
        cal.timeZone = timeZone
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        let today = cal.date(from: comps) ?? now
        if today > now { return today }
        return cal.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    func applySleepTimer(config: SleepTimerConfig) {
        sleepTimer?.invalidate()
        sleepConfig = config
        switch config.mode {
        case .off: break
        case .endOfChapter:
            // 章节播完即停：由章节结束回调处理，无需定时器
            break
        case .countdown:
            sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.minutes * 60), repeats: false) { [weak self] _ in
                self?.pause()
                self?.sleepConfig.mode = .off
            }
        case .scheduledTime:
            // build 20 必修 4：原 case 计算完 target 后空置（"next day" 分支为空注释），
            // 睡眠定时定点模式完全不生效。现补全：算出目标时刻（已过则顺延明天），
            // 按剩余时长起一次定时器，到点暂停播放并复位模式。
            let target = Self.scheduledSleepTarget(minuteOfDay: config.minuteOfDay)
            sleepTimer = Timer.scheduledTimer(withTimeInterval: max(0, target.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                self?.pause()
                self?.sleepConfig.mode = .off
            }
        }
    }

    func setSkipSettings(intro: Int, outro: Int, src: String, albumId: Int64) {
        skipStore.setIntro(intro, src: src, albumId: albumId)
        skipStore.setOutro(outro, src: src, albumId: albumId)
    }

    // MARK: - Bug 2 历史落库 + 增强 5.3 预取实现

    /// 历史落库：force=true 立即写（起播/切章/暂停）；否则按 ~5s 节流（进度观察器 1s 调用）
    private func recordHistory(force: Bool = false, positionMs: Int64? = nil) {
        guard let recorder = historyRecorder, let album = currentAlbum,
              currentChapterIdx >= 0, currentChapterIdx < currentChapters.count else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if !force, now - lastHistoryWriteMs < Self.historyThrottleMs { return }
        lastHistoryWriteMs = now
        let ch = currentChapters[currentChapterIdx]
        let pos = positionMs ?? currentPositionMs
        let dur = durationMs
        // build 19 P1-2：不再直接 spawn 无序 Task，改为入队串行排水（只保留最新）
        enqueueHistory(PendingHistoryWrite(album: album, chapter: ch, positionMs: pos, durationMs: dur))
    }

    /// 历史写入入队：待写槽位只保留最新一次（旧章节未落库前被覆盖即丢弃），
    /// 无排水任务时启动一个（同一时刻最多一个排水任务，写入严格串行）。
    private func enqueueHistory(_ write: PendingHistoryWrite) {
        historyLock.lock()
        pendingHistoryWrite = write
        let needDrain = historyDrainTask == nil
        if needDrain {
            historyDrainTask = Task { [weak self] in
                await self?.drainHistoryQueue()
            }
        }
        historyLock.unlock()
    }

    /// 串行排水循环：逐条取最新待写数据落库，取空后自退场。
    private func drainHistoryQueue() async {
        while true {
            historyLock.lock()
            let next = pendingHistoryWrite
            pendingHistoryWrite = nil
            if next == nil {
                historyDrainTask = nil
                historyLock.unlock()
                return
            }
            historyLock.unlock()
            if let recorder = historyRecorder, let w = next {
                await recorder.recordHistory(album: w.album, chapter: w.chapter,
                                             positionMs: w.positionMs, durationMs: w.durationMs)
            }
        }
    }

    /// 测试可观测：历史落库排水是否已空闲（无待写、无在途排水任务）。
    var isHistoryWriteIdle: Bool {
        historyLock.lock()
        defer { historyLock.unlock() }
        return pendingHistoryWrite == nil && historyDrainTask == nil
    }

    private func resolvedPlayUrl(forKey key: String) -> String? {
        resolveLock.lock()
        defer { resolveLock.unlock() }
        return resolvedPlayUrls[key]
    }

    private func storeResolved(key: String, url: String) {
        resolveLock.lock()
        defer { resolveLock.unlock() }
        resolvedPlayUrls[key] = url
        // 大小控制：超过上限淘汰最早写入的条目
        while resolvedPlayUrls.count > Self.resolvedCacheLimit, let first = resolvedPlayUrls.keys.first {
            resolvedPlayUrls.removeValue(forKey: first)
        }
    }

    /// 预取下一章直链：提前解析（markPaid:false 付费章静默跳过）+ AVFoundation 预热
    /// （asset.load(.isPlayable) 提前完成 DNS/TLS/媒体头交互），切章零等待。
    private func scheduleNextChapterPrefetch() {
        prefetchTask?.cancel()
        guard let album = currentAlbum,
              currentChapterIdx + 1 < currentChapters.count,
              let repository = playbackRepository else { return }
        let next = currentChapters[currentChapterIdx + 1]
        let key = PlayUri.build(src: album.source, albumId: album.albumId, chapterIdx: next.index)
        prefetchTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            if self?.resolvedPlayUrl(forKey: key) != nil { return } // 已预取过
            guard let resolved = try? await repository.getPlayUrl(
                src: album.source, albumId: album.albumId, chapterIdx: next.index,
                markPaid: false), // 静默预取：付费章不弹不打标，失败不影响播放
                !resolved.isEmpty else { return }
            guard !Task.isCancelled else { return }
            self?.storeResolved(key: key, url: resolved)
            // AVFoundation 预热（iOS 16+ async load；失败静默忽略）
            if let warmURL = URL(string: resolved) {
                let asset = AVURLAsset(url: warmURL)
                _ = try? await asset.load(.isPlayable)
            }
        }
    }

    deinit {
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        pause()
    }
}
