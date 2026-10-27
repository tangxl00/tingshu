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

/// build 33 · P0-2：代理流会话 delegate——URLSession dataTask 的 didReceive 回调
/// 按网络读取块（一次一大段 Data）respond 给 AVAssetResourceLoadingDataReceiver，
/// 取代 build 32 的 `for try await byte in bytes` 逐字节迭代（每字节一次异步
/// 挂起，真机上表现为长时间缓冲不播——用户 build 32 反馈"仍无法播放"的头号嫌疑）。
/// 口径保持不变的部分：
/// - 证书固定：质询转发给内部 PinningURLSessionDelegate，fail-closed 同
///   build 32 的 proxySession 挂载（取证 C：bilivideo.com 在后缀白名单内）；
/// - 媒体元信息回填：Content-Type→UTI、206 Content-Range 总长、可分段标志；
/// - 2xx 守卫与文案、取消语义（loadingRequest.isCancelled / 外层 Task 取消
///   均静默止流，不误报错误）。
/// 多 loadingRequest 在同一 session 上并发（AVFoundation 信息请求+多段数据请求），
/// 以 taskIdentifier 索引各自持有。
private final class ProxyStreamSessionDelegate: NSObject, URLSessionDataDelegate {
    private let pinning = PinningURLSessionDelegate()
    private let lock = NSLock()
    private var loadingRequests: [Int: AVAssetResourceLoadingRequest] = [:]
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    /// 已完成但 awaitCompletion 尚未挂起的任务（先完成后等待的边界序）
    private var finishedEarly: Set<Int> = []
    /// build 45 · 反馈 1a（错误透传）：取流层失败原文回传（阶段 play + 原始错误），
    /// 由 statusObserver .failed 拼进 playbackError——替代被 AVFoundation 吞成
    /// 裸「Cannot Open」的黑盒。仅记录，不影响 finishLoading 语义。
    private let failureRecorder: (@Sendable (String) -> Void)?

    init(failureRecorder: (@Sendable (String) -> Void)? = nil) {
        self.failureRecorder = failureRecorder
        super.init()
    }

    // MARK: 生命周期（PlaybackManager.proxyMedia 驱动）

    func attach(_ loadingRequest: AVAssetResourceLoadingRequest, to task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        loadingRequests[task.taskIdentifier] = loadingRequest
    }

    /// 挂起外层 Task 直到该 URLSessionTask 完成（didComplete 唤醒）
    func awaitCompletion(of task: URLSessionTask) async {
        await withCheckedContinuation { cont in
            lock.lock()
            defer { lock.unlock() }
            if finishedEarly.remove(task.taskIdentifier) != nil {
                cont.resume() // 任务已先行完成（如立即 4xx）：直接放行
            } else {
                continuations[task.taskIdentifier] = cont
            }
        }
    }

    private func request(for task: URLSessionTask) -> AVAssetResourceLoadingRequest? {
        lock.lock()
        defer { lock.unlock() }
        return loadingRequests[task.taskIdentifier]
    }

    private func finish(task: URLSessionTask) {
        lock.lock()
        loadingRequests.removeValue(forKey: task.taskIdentifier)
        let cont = continuations.removeValue(forKey: task.taskIdentifier)
        if cont == nil { finishedEarly.insert(task.taskIdentifier) }
        lock.unlock()
        cont?.resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let request = request(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            request.finishLoading(with: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(http.statusCode) else {
            // build 45 · 反馈 1a（错误透传）：HTTP 4xx/5xx 原文回传——设备侧
            // 「Cannot Open」的头号嫌疑层（直链被 CDN 拒绝），必须让用户截图
            // 能看到状态码而不是黑盒。
            failureRecorder?("play · 取流被拒 HTTP \(http.statusCode)（\(http.url?.host ?? "?")），请求域: \(dataTask.originalRequest?.url?.host ?? "?")")
            request.finishLoading(with: URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "音频服务器拒绝访问（HTTP \(http.statusCode)），请稍后重试",
            ]))
            completionHandler(.cancel)
            return
        }
        // 媒体元信息（首个信息请求）：Content-Type→UTI、总长度、可分段标志（口径同 build 32）
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
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let request = request(for: dataTask) else { return }
        guard !request.isCancelled else {
            dataTask.cancel() // AVFoundation 已放弃本请求（seek/切章）：止流
            return
        }
        request.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = request(for: task) else { return }
        defer { finish(task: task) }
        if request.isCancelled { return } // loadingRequest 侧取消：静默（build 32 同口径）
        if let urlError = error as? URLError, urlError.code == .cancelled { return } // 外层 Task 取消连带止流：静默
        if let error {
            // build 45 · 反馈 1a（错误透传）：网络层错误原文（域名 + 状态码 + 描述）
            // 回传——TLS/断连/超时等在设备侧的真实形态必须可见。
            let ns = error as NSError
            failureRecorder?("play · 网络错误 \(ns.domain) \(ns.code)：\(ns.localizedDescription)（\(task.currentRequest?.url?.host ?? task.originalRequest?.url?.host ?? "?")）")
            request.finishLoading(with: error)
        } else {
            request.finishLoading()
        }
    }

    /// build 45 · 反馈 1b（设备侧链路排查结论落地）：302 重定向后重注入
    /// Referer/UA——URLSession 默认重定向行为**不保证保留自定义请求头**，
    /// B站 CDN 直链常见 302 到镜像域（upos-sz-* / cn-sh-cc-*），跟随后的新请求
    /// 若丢了 Referer 即 403 → resolve/取流失败 → AVFoundation 吞成 Cannot Open。
    /// 初始请求带 Referer+UA 206 已实证（沙箱），此前缺的是重定向这一段——
    /// 本回调对每个重定向后的新请求按目标域名重新注入（BiliCdnHeadersTests
    /// 覆盖的是 applyBiliCdnHeaders 本身；本处是它在此前未被调用的路径）。
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var req = request
        let targetUrl = request.url ?? response.url
        if let targetUrl = targetUrl {
            PlaybackManager.applyBiliCdnHeaders(to: &req, url: targetUrl)
        }
        completionHandler(req)
    }

    // MARK: 证书固定（fail-closed，转发内部 PinningURLSessionDelegate）

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        pinning.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
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
    /// build 45 · 反馈 1a（错误透传）：loader 层（resolve 解析 / play 取流）失败
    /// 原文暂存——statusObserver .failed 时与 AVPlayerItem error 组合成完整
    /// 诊断文案。切章/重试时清空（见 playbackError = nil 处）。
    /// NSLock 保护：loader 队列并发写、主线程读。
    private let failureRecordLock = NSLock()
    private var loaderFailureRecord: String?

    /// build 45 · 反馈 1a（错误透传）：loader 层失败原文写入（NSLock 保护）。
    /// 供 ProxyStreamSessionDelegate 的 recorder 闭包调用（loader 队列）。
    private func recordLoaderFailure(_ message: String) {
        failureRecordLock.lock()
        loaderFailureRecord = message
        failureRecordLock.unlock()
    }

    /// build 45 · 反馈 1a（错误透传）：读取并清空 loader 层失败原文
    ///（statusObserver .failed 消费；线程安全读出后清槽防重复消费）。
    private func takeLoaderFailureRecord() -> String? {
        failureRecordLock.lock()
        defer { failureRecordLock.unlock() }
        let record = loaderFailureRecord
        loaderFailureRecord = nil
        return record
    }

    /// build 45 · 反馈 1a（错误透传）：切章/重试入口清空记录槽
    ///（与 playbackError = nil 同点位调用）。
    private func clearLoaderFailureRecord() {
        failureRecordLock.lock()
        loaderFailureRecord = nil
        failureRecordLock.unlock()
    }

    /// v1.4.3 · P0（取证 A）+ build 33 · P0-2：B站 CDN 代理取流专用 session——
    /// 带 Referer/UA（B站 CDN 实测裸请求一律 403）；证书固定 fail-closed
    /// （bilivideo.com 等已在 PinnedDomainAllowlist 后缀白名单内，取证 C 核实）。
    /// build 33：delegate 升级为 ProxyStreamSessionDelegate（内部转发质询给
    /// PinningURLSessionDelegate，挂载口径不变），dataTask 按块回调转发。
    /// 在 init 装配：存储属性初始化器不能引用其它实例属性。
    /// build 45 · 反馈 1a：构造时传入错误透传 recorder（loader 层失败原文回写）。
    private var proxyStreamDelegate: ProxyStreamSessionDelegate!
    private let proxySession: URLSession

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
        // build 33 · P0-2：代理流 session 构造器装配（配置与 build 32 完全一致：
        // Referer/UA/Origin 头 + 30s 请求超时 / 6h 资源超时；delegate 为
        // ProxyStreamSessionDelegate——证书固定转发 + dataTask 按块转发）
        let proxyConfig = URLSessionConfiguration.default
        proxyConfig.timeoutIntervalForRequest = 30
        proxyConfig.timeoutIntervalForResource = 60 * 60 * 6 // 长音频流式，资源级放宽
        proxyConfig.httpAdditionalHeaders = [
            "User-Agent": BiliAdapter.USER_AGENT,
            "Referer": BiliAdapter.REFERER,
            "Origin": BiliAdapter.REFERER,
        ]
        // build 45 · 反馈 1a（错误透传）：先构造 delegate（recorder 闭包把
        // 取流层失败原文写入 loaderFailureRecord），再构造 session——
        // 属性已改为 var + 隐式解包。注意：delegate 构造含 self 捕获，
        // 必须放在 super.init() 之后（Swift 两阶段初始化：super.init 前
        // 不允许读取 self）。
        super.init()
        let proxyDelegate = ProxyStreamSessionDelegate(failureRecorder: { [weak self] message in
            self?.recordLoaderFailure(message)
        })
        self.proxyStreamDelegate = proxyDelegate
        self.proxySession = URLSession(configuration: proxyConfig,
                                       delegate: proxyDelegate,
                                       delegateQueue: nil)
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
            // build 36 返修（CI #6 进程崩溃根因）：条目 .failed / replaceCurrentItem
            // 替换瞬间，periodic observer 会对无效 CMTime（seconds = NaN/Inf）回调——
            // Int64(NaN * 1000) 是致命转换错误（"Double value cannot be converted to
            // Int because it is either infinite or NaN"），直接杀死进程。CI 铁证：
            // testHistoryWriteSerializedLatestChapterWins 是全进程唯一「repository
            // == nil 且 play() 激活时钟」的用例——占位 URI 必然解析失败、item 必
            // .failed，即崩（三轮 0.000s + app 进程实例 12316→12874，b35 已复现、
            // 排除 b36 回归）；真机 repository 非 nil 正常加载、CMTime 有效不触发。
            // 防御：NaN/Inf 拍直接跳过，位置保持上一拍值，等条目就绪后恢复。
            guard time.seconds.isFinite else { return }
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
        // build 36 · 恢复链路语义错位修复：startIdx 有两种语义来源——
        // AlbumScreen 传 ch.index（章 index 值，首选 index 匹配正确）；恢复链路
        // （ContentView 启动恢复 / ShelfScreen 书架恢复）把 HistoryResumePlanner.locate
        // 输出的【数组位置】传进来。index 匹配失败时原先兜底到 0（章首），对非 0 基 /
        // 乱序 index 的源会恢复错章。改为按 planner 兜底同款夹取语义回退（1 基章号 →
        // 0 基数组位置的最接近值），index 0 基连续的源两种语义重合、行为不变。
        currentChapterIdx = chapters.firstIndex(where: { $0.index == startIdx })
            ?? min(max(0, startIdx), max(chapters.count - 1, 0))
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
        // build 45 · 反馈 1a（错误透传）：同步清 loader 层失败记录槽
        //（防上一章的旧诊断原文拼进本章错误文案）。
        clearLoaderFailureRecord()
        let ch = currentChapters[currentChapterIdx]
        currentChapterTitle = ch.title
        currentChapterIdx = currentChapters.firstIndex(where: { $0.chapterId == ch.chapterId }) ?? currentChapterIdx

        // build 36 返修（r4 · CI 失败 1+3 进程击杀收口）：nil repository（单测/预览配置，
        // 生产经 AppContainer 恒注入非 nil）下不再构造 AVAsset/AVPlayerItem/
        // resourceLoader/statusObserver 播放机器。取证：r4 两条 0.000s 失败 + 两次 PID
        // 更替；受害者之一 testChapterStartUsesIntroWhenNoResume 是纯静态函数用例（无
        // PM 实例、无 play()，源码可证）——崩点不在受害用例自身，而是异步余震随机砸中
        // 后续用例，按受害者画像归因不可靠。全部命中用例的共同点只有一个：占位 URI 的
        // AVAsset 必然加载失败（nil repo → loader Task 立即 finishLoading(.unsupportedURL)
        // → item .failed），AVFoundation 异步加载/取消机器全程跑在注定失败的条目上，且
        // 用例收尾时 PM 随即释放——崩溃藏在该机器与我们对象生命周期的竞态区（deinit 撤
        // observer、replaceCurrentItem 取消在途请求、KVO token 重赋值并发失效、deleg非
        // 持有引用等），属 EXC 级内存事故而非 Swift trap：play→prepare→load→loader 全链
        // 静态审计无强解包、无 try!/as!、数值转换已全部设防（周期观察器与 duration 的
        // isFinite 守卫）。CI 并行测试模式断言消息不进 test.log、xcresult 未上传、崩溃
        // 回溯不可得，沙箱无 Swift 工具链无法复现，无法指认到具体 trap 行——按约定采用
        // 「nil repository 优雅失败」收口：历史照记（含片头跳过位置）、章节标题照设、
        // 预取自守卫，播放机器整体不建，isPlaying 维持 false（play() 对空条目本就早退）。
        // 生产路径（repository 非 nil）行为完全不变。
        guard playbackRepository != nil else {
            let albumSource = currentAlbum?.source ?? "tingyou"
            let albumId = currentAlbum?.albumId ?? 0
            let startMs = Self.chapterStartMs(startPosMs: startPosMs,
                                               introSec: skipStore.intro(for: albumSource, albumId: albumId))
            recordHistory(force: true, positionMs: startMs)
            scheduleNextChapterPrefetch()
            return
        }

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
                // build 36 返修（r4 · 崩溃面加固）：流式/异常资源在 readyToPlay 瞬间
                // duration 可为 indefinite（seconds = NaN）——与周期观察器同口径先验
                // finite 再转换；Int64(NaN) 是进程击杀级致命转换错误。
                let durSec = item.duration.seconds
                self?.durationMs = durSec.isFinite ? Int64(durSec * 1000) : 0
                self?.updateNowPlaying()
                // build 27（倍速加固）：条目替换后 AVFoundation 将 rate 归零——
                // 新条目就绪时按当前 speed 与播放态重放（暂停态不起播）。
                self?.applyRate()
            } else if item.status == .failed {
                // v1.4.3 · P0（取证 D）：此前 .failed 完全静默——点章失败用户无感知。
                // 现透出人话错误（URLError 常见项映射 + ting59 站点失效特化文案），
                // Task { @MainActor } 包裹（观察回调线程不定，UI 状态须主线程更新）。
                // build 45 · 反馈 1a（错误透传）：B站 Cannot Open 三轮未解的根因之一
                // 是错误被 AVFoundation 吞成黑盒——item.error 只剩「Cannot Open」级
                // 描述，取流层（ProxyStreamSessionDelegate）/解析层（loader catch）
                // 的原始失败（HTTP 状态/OSStatus/NSURLError 原文）全部丢失。此处把
                // loader 层记录槽原文拼进 playbackError：格式「人话 + [诊断] 阶段原文」，
                // 用户截图即可直接定位坏在哪一层（resolve 解析 / play 取流）。
                let loaderRecord = self?.takeLoaderFailureRecord()
                // build 45 · 反馈 1a：player 层 NSError 原文（OSStatus domain/code +
                // userInfo）一并透出——AVFoundation 会把取流错误改写成黑盒
                // 「Cannot Open」描述，原文必须在拿到 item.error 的第一现场留存。
                let playerRecord = item.error.map { error -> String in
                    let ns = error as NSError
                    let userInfoText = ns.userInfo
                        .map { "\(String(describing: $0.key))=\(String(describing: $0.value))" }
                        .joined(separator: "; ")
                    return "player · \(ns.domain) \(ns.code)：\(ns.localizedDescription)"
                        + (userInfoText.isEmpty ? "" : " {\(userInfoText)}")
                }
                let message = item.error.map {
                    PlaybackManager.describePlaybackError($0, source: failedSource)
                } ?? "播放失败，请稍后重试"
                var diagnostic = [playerRecord, loaderRecord].compactMap { $0 }
                if !diagnostic.isEmpty {
                    diagnostic.insert("B站取证：截图反馈此段", at: 0)
                }
                let fullMessage = message + (diagnostic.isEmpty ? "" : " [诊断] " + diagnostic.joined(separator: " | "))
                Task { @MainActor [weak self] in
                    self?.playbackError = fullMessage
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
                // build 45 · 反馈 1a（错误透传）：resolve 阶段失败原文先入记录槽
                //（HTTP 状态/NSURLError 原文 + 阶段标记），供 statusObserver .failed
                // 组合输出——否则 AVFoundation 会把它吞成黑盒 Cannot Open。
                let ns = error as NSError
                self?.recordLoaderFailure("resolve · 解析失败 \(ns.domain) \(ns.code)：\(ns.localizedDescription)")
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
    /// 请求直链，喂给 AVAssetResourceLoadingRequest。支持 Range（AVFoundation
    /// 对自定义 scheme 资源会发分段请求：信息请求 + 多段数据请求，每次各自走本代理）。
    /// build 33 · P0-2：转发由逐字节 for-await 改为 dataTask + delegate 按块回调
    /// （ProxyStreamSessionDelegate 直接把网络读取块 respond 给 AVFoundation），
    /// 消除每字节一次的异步挂起开销——真机上 build 32 表现为长时间缓冲不播。
    /// Range 拼装、元信息回填、取消检查（loadingRequest.isCancelled / 外层 Task
    /// 取消经 withTaskCancellationHandler 连带取消网络任务）、证书固定口径全部不变。
    /// build 36 · 反馈 2（B 站播放 cannot open）：bilivideo.com 音频 CDN 强制校验
    /// Referer——裸请求/仅 Cookie 均 403，仅加 `Referer: https://www.bilibili.com`
    /// 即 206（沙箱分离实验实测）。proxySession 虽有 session 级 httpAdditionalHeaders，
    /// 但真机证据显示 session 级头未可靠生效，故对代理 CDN 域出站请求**请求级**
    /// 逐请求 setValue 双保险：Referer + 与 BiliAdapter 一致的 User-Agent。
    /// 仅对 B 站代理域（ProxiedCdnHosts，本函数只服务这些域）注入，其余域头保持原样。
    /// 纯静态函数，供单测直接构造 URLRequest 校验头注入逻辑。
    static func applyBiliCdnHeaders(to req: inout URLRequest, url: URL) {
        guard let host = url.host, ProxiedCdnHosts.needsProxy(host) else { return }
        req.setValue(BiliAdapter.REFERER, forHTTPHeaderField: "Referer")
        req.setValue(BiliAdapter.USER_AGENT, forHTTPHeaderField: "User-Agent")
    }

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
        Self.applyBiliCdnHeaders(to: &req, url: url)
        let task = proxySession.dataTask(with: req)
        proxyStreamDelegate.attach(request, to: task)
        // 挂起至网络任务完成；外层 loader Task 被取消（切章/停止播放）时连带取消网络任务。
        // resume 放进 operation 块：确保取消 handler 先于网络启动装好（resume 在 handler
        // 挂载前调用会有取消竞态），且 dataTask 不 resume 不发请求。
        await withTaskCancellationHandler {
            task.resume()
            await proxyStreamDelegate.awaitCompletion(of: task)
        } onCancel: {
            task.cancel()
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
        // build 38：SourceRegistry.TING59 常量已删（音源下架），存量书 kind
        // 兼容保留人话报错——指引换源收听。
        if source == "ting59", let ue = error as? URLError, isClientNetworkIssue(ue) {
            return "网络连接异常，请检查网络后重试"
        }
        if source == "ting59" {
            return "59听书网音频源当前不可用（站点侧变更，2026-10-24 实测其音频直链已被 CDN 全面拒绝），请换用其他音源收听本书"
        }
        // build 45 · 反馈 3：悦听有声书（ytysxs）全链摘除（用户点名删除）——
        // 常量与适配器已删，存量书架 ytysxs 来源的书保留（数据不删），播放时
        // 按字符串兼容报「源已下架」指引换源（SourceRegistry.YTYXSX 常量不再存在）。
        if source == "ytysxs" {
            return "悦听有声书源已下线（2026-10-27 build 45 摘除），请换用其他音源收听本书"
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
