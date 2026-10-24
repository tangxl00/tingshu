import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UniformTypeIdentifiers

/// Swift 6 并发装箱：跨 Task 隔离域持有 AVAssetResourceLoadingRequest。
/// AVFoundation 的 finishLoading / redirect 支持任意线程调用，此处仅解除编译器 Sendable 检查。
private struct LoadingRequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
}

/// v1.4.3 · P0（取证 A）：需要代理取流的 CDN 域后缀——B站 DASH 音轨直链域名
/// （bilivideo.com / akamaized.net / hdslb.com）。实测（2026-10-24 沙箱）：
/// AVPlayer 经 redirect 自行请求该 CDN 时**不带 Referer，一律 HTTP 403**
/// （带 Referer+UA 则 200, Content-Type video/mp4）——必须由 ResourceLoader
/// 代理取流注入 Referer/UA，再喂给 AVFoundation。API 域（bilibili.com 等）不在此列。
/// 其余音源（tingyou / msrc / ting59）直链此前 redirect 工作正常，维持原路径不代理。
enum ProxiedCdnHosts {
    static let suffixes: [String] = ["bilivideo.com", "akamaized.net", "hdslb.com"]

    static func needsProxy(_ host: String) -> Bool {
        suffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
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
    private let skipStore: SkipSettingsStore
    private var cancellables = Set<AnyCancellable>()

    /// v1.4.3 · P0（取证 D）：播放失败不再静默——AVPlayerItem .failed 时置人话文案，
    /// PlayerScreen 显示非阻断提示（含重试）；切章/重试时清空。
    private(set) var playbackError: String?

    /// v1.4.3 · P0（取证 A）：B站 CDN 代理取流专用 session——带 Referer/UA（B站 CDN
    /// 实测裸请求一律 403），并挂证书固定 delegate（代理路径同样 fail-closed，
    /// bilivideo.com 等已在 PinnedDomainAllowlist 后缀白名单内，取证 C 核实）。
    private let proxySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 6 // 长音频流式，资源级放宽
        config.httpAdditionalHeaders = [
            "User-Agent": BiliAdapter.USER_AGENT,
            "Referer": BiliAdapter.REFERER,
            "Origin": BiliAdapter.REFERER,
        ]
        return URLSession(configuration: config, delegate: PinningURLSessionDelegate(),
                          delegateQueue: nil)
    }()

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
            // build 27：统一走 applyRate（倍速间歇性失效加固——见 applyRate 注释）
            applyRate()
            UserDefaults.standard.set(newValue, forKey: "playback_speed")
        }
    }

    /// build 27（倍速间歇性失效加固）：统一速率重放入口。
    /// AVPlayer 的实际播放速率会在系统事件后被静默重置回默认（1.0 或暂停）：
    /// 播放条目替换（replaceCurrentItem / 自动切章新条目）、音频会话中断结束
    /// （来电、耳机拔插）、缓冲卡顿恢复、status 重新 readyToPlay——
    /// 用户在这类状态附近改倍速后，播放即呈现「选了没效果」的间歇性失效。
    /// 修复：所有此类事件汇聚到本入口，按当前 speed 与播放态重放 player.rate；
    /// 暂停态不强制起播（guard isPlaying）。
    private func applyRate() {
        guard isPlaying else { return }
        player.rate = speed
    }

    /// build 27：音频会话中断结束是否应恢复播放并重放速率（纯函数供单测）。
    /// AVAudioSession.interruptionOptions.shouldResume 语义：可恢复（多数音频场景 true）。
    static func shouldResumeAfterInterruption(typeRaw: Int, optionsRaw: Int) -> Bool {
        // ended：中断结束；shouldResume 位：系统建议恢复播放
        typeRaw == AVAudioSession.InterruptionType.ended.rawValue
            && (optionsRaw & Int(AVAudioSession.InterruptionOptions.shouldResume.rawValue)) != 0
    }
    var currentChapterTitle: String = ""
    var currentAlbumTitle: String = ""
    var coverUrl: String? = nil
    /// build 21 · 反馈 1：播放模式（顺序/单曲循环/列表循环），UserDefaults 持久化。
    private(set) var playMode: PlayMode = PlayMode(rawValue: UserDefaults.standard.integer(forKey: "play_mode")) ?? .sequence
    private static let playModeKey = "play_mode"

    // MARK: - build 25 · 片头/片尾跳过（对齐安卓 v1.3.0 item 8）

    /// 当前书片头跳过秒数（默认 0 = 关闭；设置面板 Binding 读）。
    var introSkipSeconds: Int {
        guard let album = currentAlbum else { return 0 }
        return skipStore.intro(for: album.source, albumId: album.albumId)
    }
    /// 当前书片尾跳过秒数（默认 0 = 关闭）。
    var outroSkipSeconds: Int {
        guard let album = currentAlbum else { return 0 }
        return skipStore.outro(for: album.source, albumId: album.albumId)
    }

    /// 起播位置决策（纯函数供单测）：恢复进度优先，其次片头跳过秒数。
    /// 对齐安卓 PlaybackService.applyIntroSkip（新章起播 seek 到指定秒），
    /// 但恢复播放场景保留用户上次进度，不被片头跳过覆盖。
    static func chapterStartMs(startPosMs: Int64, introSec: Int) -> Int64 {
        if startPosMs > 0 { return startPosMs }
        return Int64(max(0, introSec)) * 1000
    }

    /// 片尾跳过判定（纯函数供单测）：剩余时长 ≤ 指定秒（且确实在播放中）时触发。
    /// 对齐安卓 startOutroSkipWatcher：`remainingMs <= outroMs` 切下一章。
    static func shouldSkipOutro(positionMs: Int64, durationMs: Int64, outroSec: Int) -> Bool {
        guard outroSec > 0, durationMs > 0 else { return false }
        let remaining = durationMs - positionMs
        return remaining > 0 && remaining <= Int64(outroSec) * 1000
    }

    /// 设置当前书片头跳过秒数（对齐安卓 PlayerViewModel.setIntroSkip）。
    func setIntroSkip(_ seconds: Int) {
        guard let album = currentAlbum else { return }
        skipStore.setIntro(seconds, src: album.source, albumId: album.albumId)
    }

    /// 设置当前书片尾跳过秒数（对齐安卓 PlayerViewModel.setOutroSkip）。
    func setOutroSkip(_ seconds: Int) {
        guard let album = currentAlbum else { return }
        skipStore.setOutro(seconds, src: album.source, albumId: album.albumId)
    }

    /// build 21 · 反馈 1：章节自然播完后的动作决策（纯函数供单测）。
    /// 顺序播放到尾即停（与旧行为一致）；单曲循环重播本章；列表循环尾章后回第一章。
    enum ChapterFinishedAction: Equatable {
        case advance          // 进下一章
        case stop             // 到尾即停（顺序模式）
        case replayCurrent    // 重播本章（单曲循环）
        case wrapToFirst      // 回第一章（列表循环到尾）
    }

    static func chapterFinishedAction(playMode: PlayMode, currentIdx: Int, chapterCount: Int) -> ChapterFinishedAction {
        let isLast = currentIdx + 1 >= chapterCount
        switch playMode {
        case .sequence:
            return isLast ? .stop : .advance
        case .repeatOne:
            return .replayCurrent
        case .repeatAll:
            return isLast ? .wrapToFirst : .advance
        }
    }

    func setPlayMode(_ mode: PlayMode) {
        playMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.playModeKey)
    }

    init(playbackRepository: PlaybackRepository? = nil, skipStore: SkipSettingsStore = SkipSettingsStore()) {
        self.playbackRepository = playbackRepository
        self.skipStore = skipStore
        super.init()
        _speed = UserDefaults.standard.float(forKey: "playback_speed")
        if _speed < 0.5 || _speed > 4.0 { _speed = 1.0 }
        setupAudioSession()
        setupNowPlaying()
        addPeriodicTimeObserver()
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [weak self] _ in self?.onChapterFinished() }
            .store(in: &cancellables)
        // build 27（倍速加固）：音频会话中断结束（来电/耳机拔插）后，
        // AVPlayer 可能不恢复或恢复到默认速率——统一 applyRate 重放当前 speed。
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self = self,
                      let info = note.userInfo,
                      let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt
                else { return }
                if Self.shouldResumeAfterInterruption(typeRaw: Int(typeRaw), optionsRaw: Int(optionsRaw)) {
                    self.applyRate()
                }
            }
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
        // v1.4.3 · P0（取证 D）：新章加载即清上次播放失败提示（切章/重试共用）
        playbackError = nil
        let ch = currentChapters[currentChapterIdx]
        currentChapterTitle = ch.title
        currentChapterIdx = currentChapters.firstIndex(where: { $0.chapterId == ch.chapterId }) ?? currentChapterIdx

        // v1.4.3 · P0（取证 D）：statusObserver 须能引用当前源（ting59 失效文案特化用）
        let failedSource = currentAlbum?.source ?? ""
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
                // build 27（倍速加固）：条目替换后 AVFoundation 将 rate 归零——
                // 新条目就绪时按当前 speed 与播放态重放（暂停态不起播）。
                self?.applyRate()
            } else if item.status == .failed {
                // v1.4.3 · P0（取证 D）：此前 .failed 完全静默——点章失败用户无感知。
                // 现透出人话错误（URLError 常见项映射 + ting59 站点失效特化文案），
                // Task { @MainActor } 包裹（观察回调线程不定，UI 状态须主线程更新）。
                let message = item.error.map {
                    PlaybackManager.describePlaybackError($0, source: failedSource)
                } ?? "播放失败，请稍后重试"
                Task { @MainActor [weak self] in
                    self?.playbackError = message
                }
            }
        }
        player.replaceCurrentItem(with: item)
        // build 25（对齐安卓 v1.3.0 item 8 applyIntroSkip）：新章起播应用片头跳过秒数；
        // 恢复播放（startPosMs > 0）保留用户上次进度，不被片头跳过覆盖。
        let albumSource = currentAlbum?.source ?? "tingyou"
        let albumId = currentAlbum?.albumId ?? 0
        let startMs = Self.chapterStartMs(startPosMs: startPosMs,
                                           introSec: skipStore.intro(for: albumSource, albumId: albumId))
        if startMs > 0 {
            player.seek(to: CMTime(seconds: Double(startMs) / 1000.0, preferredTimescale: 1000))
        }
        if autoPlay {
            isPlaying = true
            // build 27：isPlaying 先置位，applyRate 内 guard 通过（条目尚在加载时
            // 由 statusObserver readyToPlay 再重放一次，双保险）
            applyRate()
            listenStartMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
        updateNowPlaying()
        // Bug 2：起播/切章立即落一次历史（记录新章节起点；build 25：含片头跳过后的位置）
        recordHistory(force: true, positionMs: startMs)
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
        // 增强 5.3：预取命中 → 直接服务，省一次网络解析（切章零等待）。
        // v1.4.3 · P0：命中后不总是 redirect——按直链域名分流（代理 / redirect），
        // B站 CDN 必须代理（裸请求 403，见 ProxiedCdnHosts 注释）。
        if let cached = resolvedPlayUrl(forKey: url.absoluteString) {
            return serveResolved(LoadingRequestBox(request: loadingRequest), playUrl: cached)
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
                    src: parsed.src, albumId: parsed.albumId, chapterIdx: parsed.chapterIdx,
                    detailPath: self?.currentAlbum?.detailPath)
                // 解析结果顺手入缓存（同一章 seek/重开不再重复解析）
                self?.storeResolved(key: cacheKey, url: playUrl)
                guard let resolvedSelf = self else { return }
                // v1.4.3 · P0：解析完成同样按域名分流服务
                if !resolvedSelf.serveResolved(box, playUrl: playUrl) {
                    box.request.finishLoading(with: URLError(.badURL))
                }
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

    /// v1.4.3 · P0（取证 A）：按直链域名分流服务 AVFoundation——
    /// - B站 CDN 域（ProxiedCdnHosts）：代理取流（带 Referer/UA 由 proxySession 请求，
    ///   响应数据喂给 loadingRequest；AVPlayer 自行请求必 403，不能 redirect）；
    /// - 其余源：维持既有 redirect 语义（build 29 起线上验证可行，不动）。
    /// 返回 false 仅当直链 URL 不合法（调用方兜底 finishLoading）。
    @discardableResult
    private func serveResolved(_ box: LoadingRequestBox, playUrl: String) -> Bool {
        guard let redirectURL = URL(string: playUrl) else { return false }
        guard let host = redirectURL.host, ProxiedCdnHosts.needsProxy(host) else {
            // 非代理域：原 redirect 语义（AVPlayer 自行取流）
            box.request.redirect = URLRequest(url: redirectURL)
            box.request.response = HTTPURLResponse(
                url: redirectURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            box.request.finishLoading()
            return true
        }
        // 代理域：接管数据流（loaderTasks 复用既有取消管理）
        loaderLock.lock()
        let seq = loaderTaskSeq
        loaderTaskSeq += 1
        loaderLock.unlock()
        let task = Task { [weak self] in
            await self?.proxyMedia(box: box, url: redirectURL)
            self?.removeLoaderTask(seq)
        }
        loaderLock.lock()
        loaderTasks[seq] = task
        loaderLock.unlock()
        return true
    }

    /// v1.4.3 · P0（取证 A）：代理取流——用 proxySession（Referer/UA + 证书固定）
    /// 请求直链，流式喂给 AVAssetResourceLoadingRequest。支持 Range（AVFoundation
    /// 对自定义 scheme 资源会发分段请求：信息请求 + 多段数据请求，每次各自走本代理）。
    private func proxyMedia(box: LoadingRequestBox, url: URL) async {
        let request = box.request
        var req = URLRequest(url: url)
        // 按本 loadingRequest 的数据区间组装 Range（requestsAllDataToEndOfResource = 开区间）
        if let dataRequest = request.dataRequest {
            if dataRequest.requestsAllDataToEndOfResource {
                req.setValue("bytes=\(dataRequest.requestedOffset)-", forHTTPHeaderField: "Range")
            } else {
                let end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1
                req.setValue("bytes=\(dataRequest.requestedOffset)-\(max(end, dataRequest.requestedOffset))",
                             forHTTPHeaderField: "Range")
            }
        }
        do {
            let (bytes, response) = try await proxySession.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                request.finishLoading(with: URLError(.badServerResponse))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                request.finishLoading(with: URLError(.badServerResponse, userInfo: [
                    NSLocalizedDescriptionKey: "音频服务器拒绝访问（HTTP \(http.statusCode)），请稍后重试",
                ]))
                return
            }
            // 媒体元信息（首个信息请求）：Content-Type→UTI、总长度、可分段标志
            if let info = request.contentInformationRequest {
                if let mime = http.mimeType {
                    info.contentType = UTType(mimeType: mime)?.identifier ?? UTType.audio.identifier
                }
                if http.statusCode == 206,
                   let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                   let total = contentRange.split(separator: "/").last.flatMap({ Int64($0) }),
                   total > 0 {
                    info.contentLength = total
                } else {
                    info.contentLength = http.expectedContentLength
                }
                info.isByteRangeAccessSupported = true
            }
            // 流式转发：64KB 一批 respond；加载请求被取消（seek/切章）即止
            var buffer = [UInt8]()
            buffer.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                if request.isCancelled || Task.isCancelled { return } // 已取消：静默止流
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    request.dataRequest?.respond(with: Data(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { request.dataRequest?.respond(with: Data(buffer)) }
            request.finishLoading()
        } catch {
            if request.isCancelled { return }
            request.finishLoading(with: error)
        }
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

    /// 章节列表页直接跳章（PlayerScreen 的 ChapterListSheet 接线）
    func playChapter(at index: Int) {
        guard index >= 0, index < currentChapters.count else { return }
        pause()
        currentChapterIdx = index
        loadCurrentChapter(autoPlay: true)
    }

    /// v1.4.3 · P0（取证 D）：播放失败重试——重走当前章加载（清错误后重建
    /// AVPlayerItem，解析缓存若在则直接分流服务）。PlayerScreen 提示区接线。
    func retryCurrentChapter() {
        guard currentChapters.indices.contains(currentChapterIdx) else { return }
        loadCurrentChapter(autoPlay: true)
    }

    /// v1.4.3 · P0（取证 D）：播放失败人话文案——URLError 常见项映射；
    /// ting59 特化：非客户端网络错误的失败按站点侧源失效提示（取证 B 实测：
    /// xmcdn 直链已全组合 403/404，带 Referer+cookie 的"正确"请求同样被拒，
    /// 站点自身网页播放器裸用同一 URL，非 App 可修，如实告知换源）。
    static func describePlaybackError(_ error: Error, source: String) -> String {
        let isClientNetworkIssue: (URLError) -> Bool = { ue in
            switch ue.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .cancelled:
                return true
            default:
                return false
            }
        }
        if source == SourceRegistry.TING59, let ue = error as? URLError, isClientNetworkIssue(ue) {
            return "网络连接异常，请检查网络后重试"
        }
        if source == SourceRegistry.TING59 {
            return "59听书网音频源当前不可用（站点侧变更，2026-10-24 实测其音频直链已被 CDN 全面拒绝），请换用其他音源收听本书"
        }
        if let ue = error as? URLError {
            switch ue.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络连接不可用，请检查网络后重试"
            case .timedOut:
                return "连接音频服务器超时，请稍后重试"
            case .badServerResponse:
                return "音频服务器响应异常，请稍后重试"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "无法连接音频服务器，请稍后重试"
            default:
                return "播放失败，请稍后重试"
            }
        }
        return "播放失败，请稍后重试（\(error.localizedDescription)）"
    }

    func play() {
        guard player.currentItem != nil else { return }
        isPlaying = true
        // build 27：先置播放态再 applyRate（guard isPlaying 语义要求）
        applyRate()
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
        // build 21 · 反馈 1：按播放模式决定播完后的动作（决策逻辑抽成纯函数供单测）
        switch Self.chapterFinishedAction(playMode: playMode,
                                          currentIdx: currentChapterIdx,
                                          chapterCount: currentChapters.count) {
        case .advance:
            nextChapter()
        case .stop:
            isPlaying = false // 到尾即停（保持章节不动，用户可手动续播）
        case .replayCurrent:
            pause()
            loadCurrentChapter(startPosMs: 0, autoPlay: true)
        case .wrapToFirst:
            pause()
            currentChapterIdx = 0
            loadCurrentChapter(startPosMs: 0, autoPlay: true)
        }
    }

    private func checkOutroSkip() {
        guard let album = currentAlbum else { return }
        let outro = skipStore.outro(for: album.source, albumId: album.albumId)
        // build 25：判定抽成纯函数 shouldSkipOutro（供单测）；
        // 触发切下一章（与自动连播同入口 nextChapter，末章不越界——对齐安卓 seekToNextMediaItem）
        if Self.shouldSkipOutro(positionMs: currentPositionMs, durationMs: durationMs, outroSec: outro) {
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

    // build 25：原 setSkipSettings(intro:outro:src:albumId:) 无调用方（UI 从未接线），
    // 被 setIntroSkip / setOutroSkip（对齐安卓 VM 命名、按 currentAlbum 定位书）替代后删除。

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
            // v1.4.2 · P2-1（质检）：预取补传 detailPath——此前缺参时 BILI 必抛 badURL
            // 被静默吞掉（切章预取全失效）、TING59 导入书回退 String(albumId) 解析到
            // 错误书页；与 resourceLoader 主路径（detailPath: currentAlbum?.detailPath）
            // 口径对齐，预取与播放解析到同一章。
            guard let resolved = try? await repository.getPlayUrl(
                src: album.source, albumId: album.albumId, chapterIdx: next.index,
                detailPath: album.detailPath,
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
