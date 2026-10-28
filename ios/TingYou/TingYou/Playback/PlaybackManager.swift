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
    /// build 46：taskIdentifier → 原始 Range 头（重定向重建用，见 attach 注释）
    private var taskRanges: [Int: String] = [:]
    /// build 47 · 防御层：taskIdentifier → 流内「下一字节」偏移——didReceive
    /// response 时按 Content-Range / 200 初始化（实际服务起始），每块数据
    /// 处理后推进。respond 前据此对齐 dataRequest 期望偏移（丢错位前缀）。
    private var taskOffsets: [Int: Int64] = [:]
    /// build 47 · 防御层：已记过「偏移对齐」诊断的任务（每任务只记一次，
    /// 防止多块数据刷屏）。
    private var taskSkipLogged: Set<Int> = []
    /// build 47 · Content-Type 嗅探兜底：响应期未改写成功（B站域
    /// octet-stream 但 URL 路径无扩展名线索）的任务，等首个覆盖流内
    /// 偏移 4..<8 的数据块按 ftyp 盒嗅探（didReceive data）。
    private var taskSniffPending: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    /// 已完成但 awaitCompletion 尚未挂起的任务（先完成后等待的边界序）
    private var finishedEarly: Set<Int> = []
    /// build 48 · 需求 4（B站取流超时二分）：本会话累计 respond 给
    /// AVFoundation 的净载荷字节数（偏移对齐丢弃的字节不计——对条目就绪
    /// 无贡献）。watchdog 到点采样，判定「零字节到达（真挂起，切镜像）」
    /// 与「数据缓慢到达（延长观察）」两种形态。条目重建时由
    /// PlaybackManager 重置。与 loadingRequests 等共用一把 lock。
    private var forwardedBytesTotal: Int64 = 0
    /// build 45 · 反馈 1a（错误透传）：取流层失败原文回传（阶段 play + 原始错误），
    /// 由 statusObserver .failed 拼进 playbackError——替代被 AVFoundation 吞成
    /// 裸「Cannot Open」的黑盒。仅记录，不影响 finishLoading 语义。
    private let failureRecorder: (@Sendable (String) -> Void)?
    /// build 46 · 反馈 1 增强：取流层元信息回传（HTTP 状态 + Content-Type +
    /// 实际服务域名）——成功路径也记录。下次失败时一眼看出喂给 AVPlayer 的
    /// 是「video/mp4 @ cn-sh-cc-xx.bilivideo.com」还是别的（真机 -12847 取证
    /// 的关键盲区：proxy 2xx 有内容但 AVPlayer 拒收，此前无法知道内容是什么）。
    private let metaRecorder: (@Sendable (String) -> Void)?

    init(failureRecorder: (@Sendable (String) -> Void)? = nil,
         metaRecorder: (@Sendable (String) -> Void)? = nil) {
        self.failureRecorder = failureRecorder
        self.metaRecorder = metaRecorder
        super.init()
    }

    // MARK: 生命周期（PlaybackManager.proxyMedia 驱动）

    func attach(_ loadingRequest: AVAssetResourceLoadingRequest, to task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        loadingRequests[task.taskIdentifier] = loadingRequest
        // build 46 · B站真机 -12847 根因修复：attach 时保存本 loadingRequest 的
        // Range 头——重定向后 URLSession 构造的新请求不保证保留自定义头；
        // Range 丢失时 CDN 返回 200 全量数据，respond 给期望偏移的 dataRequest
        // 造成数据错位，AVFoundation 报 -12847「media format is not supported」
        //（真机证据：player · -11828 Cannot Open {底层 -12847}；沙箱分离实验
        //  证实 CDN 对 Range 请求正确回 206 partial，问题在 App 侧转发链）。
        if let dr = loadingRequest.dataRequest {
            taskRanges[task.taskIdentifier] = Self.rangeHeader(for: dr)
        }
    }

    /// build 46：按 dataRequest 组装 Range 头（口径与 proxyMedia 一致）。
    static func rangeHeader(for dr: AVAssetResourceLoadingDataRequest) -> String? {
        if dr.requestsAllDataToEndOfResource {
            return "bytes=\(dr.requestedOffset)-"
        }
        let end = dr.requestedOffset + Int64(dr.requestedLength) - 1
        return "bytes=\(dr.requestedOffset)-\(max(end, dr.requestedOffset))"
    }

    private func rangeHeader(for task: URLSessionTask) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return taskRanges[task.taskIdentifier]
    }

    // MARK: build 47 · 偏移对齐防御层（与 b46 Range 重注入互为双保险）

    /// 解析 Content-Range「bytes start-end/total」的 start（200 全量响应
    /// 无此头，由调用方按 0 处理）。兼容「bytes=」等写法容错。
    static func contentRangeStart(_ header: String) -> Int64? {
        let parts = header.split(whereSeparator: { $0 == " " || $0 == "=" })
        guard parts.count >= 2 else { return nil }
        let bounds = parts[1].split(separator: "-")
        guard let start = bounds.first.flatMap({ Int64($0) }) else { return nil }
        return start
    }

    /// 当前流内「下一字节」偏移（未初始化按 0——200 全量的默认事实起点）。
    private func streamOffset(for task: URLSessionTask) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return taskOffsets[task.taskIdentifier] ?? 0
    }

    /// 记录响应实际起始偏移（didReceive response 调用；206 按 Content-Range，其余按 0）。
    private func setStreamOffset(_ offset: Int64, for task: URLSessionTask) {
        lock.lock()
        taskOffsets[task.taskIdentifier] = offset
        lock.unlock()
    }

    /// 数据块处理完成后推进「下一字节」偏移。
    private func advanceStreamOffset(for task: URLSessionTask, by delta: Int64) {
        lock.lock()
        taskOffsets[task.taskIdentifier, default: 0] += delta
        lock.unlock()
    }

    /// 「偏移对齐」诊断——每任务记一次（metaRecorder，失败时随诊断透出）。
    private func noteAlignmentSkip(task: URLSessionTask, skipped: Int, want: Int64, from: Int64) {
        lock.lock()
        let first = taskSkipLogged.insert(task.taskIdentifier).inserted
        lock.unlock()
        if first {
            metaRecorder?("play · 偏移对齐: 丢弃请求偏移前 \(skipped) 字节（dataRequest 期望自 \(want) 起，实收自 \(from) 起）——Range 丢失防御层生效")
        }
    }

    /// build 47 · 嗅探兜底记账（锁内三件套：标记 / 查询 / 清除）。
    private func markSniffPending(_ task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        taskSniffPending.insert(task.taskIdentifier)
    }

    private func sniffPending(_ task: URLSessionTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return taskSniffPending.contains(task.taskIdentifier)
    }

    private func clearSniffPending(_ task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        taskSniffPending.remove(task.taskIdentifier)
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
        taskRanges.removeValue(forKey: task.taskIdentifier)
        // build 47 · 防御层：偏移与对齐诊断记账同步清理（防串任务）
        taskOffsets.removeValue(forKey: task.taskIdentifier)
        taskSkipLogged.remove(task.taskIdentifier)
        // build 47 · 嗅探兜底：任务结束未嗅探到也不再挂起（防串任务）
        taskSniffPending.remove(task.taskIdentifier)
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
        // build 46 · 反馈 1 增强：元信息回传（成功路径也记）——HTTP 状态 +
        // Content-Type + 实际服务域名进诊断（失败时可见「喂的是什么」）。
        metaRecorder?("play · HTTP \(http.statusCode) \(http.mimeType ?? "?") @ \(http.url?.host ?? "?")")
        // build 47 · 防御层初始化：记录本响应的实际起始偏移——206 按
        // Content-Range 的 start（服务端真正开始传的位置），其余（200 全量，
        // 即 Range 头丢失的形态）按 0。didReceive data 据此对齐。
        if http.statusCode == 206,
           let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let start = Self.contentRangeStart(cr) {
            setStreamOffset(start, for: dataTask)
        } else {
            setStreamOffset(0, for: dataTask)
        }
        // build 47 · B站 CDN octet-stream 修复（真机证据：play · HTTP 206
        // application/octet-stream @ upos-sz-mirrorbd.bilivideo.com）——镜像
        // 节点把 DASH 音轨标成 octet-stream，AVPlayer 的
        // contentInformationRequest 拿到后按不支持格式拒收 → -12847。
        // B站代理域内按路径线索改写（.m4s → audio/mp4），改写前后都进
        // [诊断]（下次截图直接看到「octet-stream → audio/mp4 已改写」）；
        // 无路径线索的挂起等首块 ftyp 嗅探（didReceive data）。非 B站域、
        // 非 octet-stream 一律不改写。
        let originalMime = http.mimeType
        let effectiveMime = PlaybackManager.rewrittenBiliContentType(
            originalMime: originalMime,
            url: http.url ?? dataTask.originalRequest?.url)
        if let original = originalMime, let effective = effectiveMime, effective != original {
            metaRecorder?("play · Content-Type 改写: \(original) → \(effective)（\(http.url?.host ?? "?")）——B站 CDN octet-stream 修复")
        } else if originalMime?.lowercased() == "application/octet-stream",
                  let host = (http.url ?? dataTask.originalRequest?.url)?.host,
                  ProxiedCdnHosts.needsProxy(host) {
            markSniffPending(dataTask)
        }
        // 媒体元信息（首个信息请求）：Content-Type→UTI、总长度、可分段标志（口径同 build 32）
        if let info = request.contentInformationRequest {
            if let mime = effectiveMime {
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
        guard let dr = request.dataRequest else { return }
        // build 47 · Content-Type 嗅探兜底：响应期无路径线索的 B站
        // octet-stream 流，首个覆盖流内偏移 4..<8 的块按 ftyp 盒判 fMP4 →
        // audio/mp4，改写结果回填 contentInformationRequest（finishLoading 前
        // 生效）并进 [诊断]。嗅探在偏移对齐/推进之前用原始流位置判定。
        if sniffPending(dataTask) {
            if let sniffed = PlaybackManager.sniffedBiliMp4Mime(data: data, streamOffset: streamOffset(for: dataTask)) {
                clearSniffPending(dataTask)
                if let info = request.contentInformationRequest {
                    info.contentType = UTType(mimeType: sniffed)?.identifier ?? UTType.audio.identifier
                }
                metaRecorder?("play · Content-Type 改写: application/octet-stream → \(sniffed)（\(dataTask.currentRequest?.url?.host ?? dataTask.originalRequest?.url?.host ?? "?")，ftyp 嗅探）——B站 CDN octet-stream 修复")
            }
        }
        // build 47 · B站偏移对齐防御层（b46 Range 重注入之外的第二层保险，
        // 两层任一生效即可播）：respond 前按本任务请求的起始偏移与实际收到
        // 的字节位置对齐——若 Range 头在重定向后丢失（CDN 回 200 全量），
        // 数据从 0 开始而 dataRequest 期望 requestedOffset，直接 respond 会
        // 数据错位 → moov 解析失败 → AVFoundation -12847「media format is
        // not supported」。此处丢弃请求偏移之前的字节，只把对齐后的数据
        // respond 给 AVFoundation（200 全量响应也能切对偏移）。
        var payload = data
        let streamOffset = self.streamOffset(for: dataTask)
        let want = dr.requestedOffset
        if streamOffset < want {
            let skip = Int(want - streamOffset)
            if skip >= payload.count {
                // 整块都在请求偏移之前：全丢，推进偏移等后续块
                noteAlignmentSkip(task: dataTask, skipped: payload.count, want: want, from: streamOffset)
                advanceStreamOffset(for: dataTask, by: Int64(payload.count))
                return
            }
            noteAlignmentSkip(task: dataTask, skipped: skip, want: want, from: streamOffset)
            payload = payload.subdata(in: skip..<payload.count)
        }
        advanceStreamOffset(for: dataTask, by: Int64(data.count))
        addForwardedBytes(Int64(payload.count))
        dr.respond(with: payload)
    }

    // MARK: build 48 · 需求 4 —— watchdog 转发字节采样（锁保护，供
    // PlaybackManager 超时形态判定；静态可测的形态判定在
    // PlaybackManager.streamStallVerdict，单测直调）

    /// 累加本会话净转发字节（didReceive data 转发点调用）。
    private func addForwardedBytes(_ delta: Int64) {
        lock.lock()
        forwardedBytesTotal += delta
        lock.unlock()
    }

    /// 当前累计（watchdog 到点采样）。
    var totalForwardedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return forwardedBytesTotal
    }

    /// 条目重建起点归零（镜像重试 / 切章 / 重试共用）。
    func resetForwardedBytes() {
        lock.lock()
        forwardedBytesTotal = 0
        lock.unlock()
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
        // build 46 · B站真机 -12847 根因修复：重定向重建 Range——URLSession 的
        // 重定向新请求不保证保留 Range 头（b45 只补了 Referer/UA 重注入，Range
        // 仍是丢失面）。丢失时 CDN 对重定向后请求回 200 全量数据（沙箱实证 CDN
        // 正确支持 206 partial），respond 给期望 bytes=X- 的 dataRequest → 数据
        // 错位 → AVFoundation -12847「media format is not supported」（真机
        // Cannot Open 的底层错误）。直连节点（无 302）不受影响——与「部分稿件
        // 能播、部分不能」的真机现象吻合。
        if let range = rangeHeader(for: task),
           req.value(forHTTPHeaderField: "Range") != range {
            req.setValue(range, forHTTPHeaderField: "Range")
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
    /// build 46 · 反馈 1 增强：loader 元信息（成功路径也记，见 recordLoaderMeta）
    private var loaderMetaRecord: String?

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
        loaderMetaRecord = nil
        failureRecordLock.unlock()
    }

    /// build 46 · 反馈 1 增强：loader 层元信息槽（HTTP 状态 + Content-Type +
    /// 域名；resolve 直链域名也入此槽）——失败/超时诊断时拼出「喂的是什么」。
    private func recordLoaderMeta(_ message: String) {
        failureRecordLock.lock()
        loaderMetaRecord = message
        failureRecordLock.unlock()
    }

    private func takeLoaderMetaRecord() -> String? {
        failureRecordLock.lock()
        defer { failureRecordLock.unlock() }
        return loaderMetaRecord
    }

    /// build 45 · CI 第一轮（反馈 2a）：章节加载中间态——点章到 readyToPlay
    /// 之间的可感知反馈（PlayerScreen「加载中…」）。CI 用例 H 30 秒空窗的
    /// 一半根因：既无播放态也无错误文案的静默区间，现在至少有中间态或超时诊断。
    private(set) var isChapterLoading = false
    /// build 45 · CI 第一轮（反馈 2b）：取流看门狗——20s 内条目未 readyToPlay
    /// 且未 .failed，按失败透传处理（「取流超时」+ [诊断] loader 原文）。
    /// AVFoundation 缓冲挂起不主动报错，这是 H 空窗的另一半根因。
    /// readyToPlay / .failed / 切章 / 重试 四处取消。
    private var playbackWatchdog: DispatchWorkItem?

    /// build 48 · 需求 4（B站取流超时 · 镜像重试）：当前章的镜像候选链
    ///（getPlayUrlCandidates 返回主选 + backup_url 镜像，主选已服务，
    /// 此处存剩余备选）与已切换次数。watchdog 判定「零字节 / 中途停滞」
    /// 挂起形态时自动取下一候选重建条目（storeResolved 重定向占位 URI
    /// 缓存 → loadCurrentChapter 缓存命中直接服务新镜像）；链耗尽或达
    /// 上限才向用户报错。loader Task（后台）与 watchdog（main asyncAfter）
    /// 并发访问，统一经 mirrorLock。
    private var mirrorCandidates: [String] = []
    private var mirrorAttempts = 0
    private let mirrorLock = NSLock()
    /// build 48 · 需求 4：watchdog 慢速延长观察的采样基线与延长轮次——
    /// 到点采样 totalForwardedBytes，增量 ≥ streamProgressFloorBytes 视为
    /// 「数据在缓慢到达」延长观察（不掐可恢复的缓冲），否则按挂起处理。
    private var watchdogByteBaseline: Int64 = 0
    private var watchdogExtensions = 0

    /// v1.4.3 · P0（取证 A）+ build 33 · P0-2：B站 CDN 代理取流专用 session——
    /// 带 Referer/UA（B站 CDN 实测裸请求一律 403）；证书固定 fail-closed
    /// （bilivideo.com 等已在 PinnedDomainAllowlist 后缀白名单内，取证 C 核实）。
    /// build 33：delegate 升级为 ProxyStreamSessionDelegate（内部转发质询给
    /// PinningURLSessionDelegate，挂载口径不变），dataTask 按块回调转发。
    /// 在 init 装配：存储属性初始化器不能引用其它实例属性。
    /// build 45 · 反馈 1a：构造时传入错误透传 recorder（loader 层失败原文回写）。
    private var proxyStreamDelegate: ProxyStreamSessionDelegate!
    /// build 45 · 反馈 1a：session 与 delegate 都改为 var + 隐式解包——delegate
    /// 闭包捕获 self，只能在 super.init() 之后构造（Swift 两阶段初始化），
    /// session 挂 delegate 故同批次赋值；init 尾部即完成，运行时非空。
    private var proxySession: URLSession!

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
        let proxyDelegate = ProxyStreamSessionDelegate(
            failureRecorder: { [weak self] message in
                self?.recordLoaderFailure(message)
            },
            metaRecorder: { [weak self] message in
                self?.recordLoaderMeta(message)
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

    private func loadCurrentChapter(startPosMs: Int64 = 0, autoPlay: Bool = true,
                                    keepMirrorChain: Bool = false) {
        guard currentChapterIdx < currentChapters.count else { return }
        // v1.4.3 · P0（取证 D）：新章加载即清上次播放失败提示（切章/重试共用）
        playbackError = nil
        // build 45 · 反馈 1a（错误透传）：同步清 loader 层失败记录槽
        //（防上一章的旧诊断原文拼进本章错误文案）。
        clearLoaderFailureRecord()
        // build 45 · CI 第一轮（反馈 2a/2b）：新章加载置中间态 + 重置看门狗
        //（切章/重试共用入口，旧看门狗必须作废——否则上一章的超时会误报进新章）。
        playbackWatchdog?.cancel()
        playbackWatchdog = nil
        // build 48 · 需求 4：watchdog 超时形态采样归零（新条目从 0 计）；
        // 镜像链默认随新条目失效（切章/用户重试），仅镜像重试自身
        // （keepMirrorChain=true）保留剩余候选与已切次数，链不中断。
        proxyStreamDelegate?.resetForwardedBytes()
        watchdogByteBaseline = 0
        watchdogExtensions = 0
        if !keepMirrorChain {
            mirrorLock.lock()
            mirrorCandidates = []
            mirrorAttempts = 0
            mirrorLock.unlock()
        }
        isChapterLoading = true
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
                // build 45 · CI 第一轮（反馈 2a/2b）：就绪即清中间态 + 撤看门狗
                self?.playbackWatchdog?.cancel()
                self?.playbackWatchdog = nil
                self?.isChapterLoading = false
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
                self?.playbackWatchdog?.cancel()
                self?.playbackWatchdog = nil
                self?.isChapterLoading = false
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
                // build 46 · 反馈 1 增强：loader 元信息（HTTP 状态/Content-Type/
                // 域名 + resolve 直链域）一并拼进诊断——失败时直接可见
                //「喂给 AVPlayer 的是什么、从哪个域拿的」。
                if let meta = self?.takeLoaderMetaRecord() {
                    diagnostic.append(meta)
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
        // build 45 · CI 第一轮（反馈 2b）：取流看门狗——20s 未就绪且未报错，
        // 视为取流挂起（缓冲态 AVFoundation 不主动 .failed），按失败透传：
        // 「取流超时」+ [诊断] loader 层原文 + 取证指引（H 判定窗口 30s 内必达）。
        // build 48 · 需求 4（B站取流超时二分 + 镜像重试，真机《择日飞升》
        // 49:38 卡 00:05 · HTTP 206 video/mp4 @ upos-sz-estgcos 取证）：
        // 到点先采样代理层净转发字节，按 streamStallVerdict 二分——
        // ① 数据缓慢到达（增量 ≥ 16KB）：不掐可恢复的缓冲，重挂 20s 延长观察
        //    （诊断留痕「缓慢到达 + 增量」），readyToPlay 到达即自动撤；
        // ② 零字节到达 / 数据中途停滞：真挂起——自动取 backup_url 候选链
        //    下一镜像重建条目（storeResolved 重定向占位 URI 缓存，
        //    loadCurrentChapter 缓存命中直接服务新镜像，进度/记账干净重来），
        //    最多 mirrorRetryLimit 次；镜像耗尽仍停滞才向用户报错，文案按
        //    「零字节到达 / 中途停滞」区分标注。
        let watchdogUri = uri
        let watchdog = DispatchWorkItem { [weak self] in
            self?.handleStreamWatchdogFired(uri: watchdogUri, extended: false)
        }
        playbackWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: watchdog)
    }

    /// build 48 · 需求 4：watchdog 重挂（慢速延长观察轮次共用同一闭包语义）。
    private func scheduleStreamWatchdog(uri: String) {
        let watchdog = DispatchWorkItem { [weak self] in
            self?.handleStreamWatchdogFired(uri: uri, extended: true)
        }
        playbackWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: watchdog)
    }

    /// build 48 · 需求 4：watchdog 到点的统一处理——采样代理层净转发字节，
    /// 按 streamStallVerdict 二分：progressing 延长观察（重挂 20s，readyToPlay
    /// 到达即自动撤）；停滞（零字节 / 中途停滞）先自动切 backup 镜像重建条目
    /// （takeNextMirrorCandidate 原子出队，storeResolved 重定向占位 URI 缓存后
    /// loadCurrentChapter 缓存命中直接服务新镜像——不重走 playurl 解析，同一
    /// 解析结果只会拿到同一主选），链耗尽 / 达上限才报错，文案区分两种停滞
    /// 形态并标注已切镜像次数。extended=true 仅诊断文案区分首轮 / 延长轮。
    private func handleStreamWatchdogFired(uri: String, extended: Bool) {
        guard playbackError == nil else { return }
        let forwarded = proxyStreamDelegate?.totalForwardedBytes ?? 0
        let verdict = Self.streamStallVerdict(previousBytes: watchdogByteBaseline,
                                              currentBytes: forwarded)
        let shapeText: String
        switch verdict {
        case .progressing(let delta):
            watchdogByteBaseline = forwarded
            watchdogExtensions += 1
            recordLoaderMeta("watchdog · 数据缓慢到达（20s 增量 \(delta) 字节，累计 \(forwarded)），延长观察第 \(watchdogExtensions) 轮")
            scheduleStreamWatchdog(uri: uri)
            return
        case .stalledNoData:
            shapeText = "零字节到达"
        case .stalledAfterData(let bytes):
            shapeText = "数据中途停滞（先到达 \(bytes) 字节后停止）"
        }
        // 真挂起：优先自动切镜像（至少 1 次），链耗尽才报错。
        if let next = takeNextMirrorCandidate() {
            let host = URL(string: next)?.host ?? "?"
            recordLoaderMeta("watchdog · \(extended ? "延长观察后" : "")\(shapeText)，自动切换镜像第 \(currentMirrorAttempts()) 次 → \(host)")
            storeResolved(key: uri, url: next)
            Task { @MainActor [weak self] in
                self?.loadCurrentChapter(autoPlay: true, keepMirrorChain: true)
            }
            return
        }
        let attempts = currentMirrorAttempts()
        let attemptsText = attempts > 0
            ? "，已自动换镜像 \(attempts) 次仍无进展"
            : "，无可用 backup 镜像"
        let windowText = extended
            ? "慢速延长观察后仍\(shapeText)（累计观察 \(20 * (watchdogExtensions + 1)) 秒无就绪"
            : "20 秒观察窗内\(shapeText)"
        let loaderRecord = takeLoaderFailureRecord()
        var diagnostic = [
            "取流超时 · \(windowText)（缓冲挂起，AVFoundation 未报 .failed\(attemptsText)）",
        ]
        if let loaderRecord { diagnostic.append(loaderRecord) }
        if let meta = takeLoaderMetaRecord() { diagnostic.append(meta) }
        diagnostic.insert("B站取证：截图反馈此段", at: 0)
        let fullMessage = "加载超时，请重试 [诊断] " + diagnostic.joined(separator: " | ")
        playbackWatchdog = nil
        Task { @MainActor [weak self] in
            self?.isChapterLoading = false
            self?.playbackError = fullMessage
        }
    }

    /// build 48 · 需求 4：取下一镜像候选（nil = 链耗尽或达 mirrorRetryLimit）。
    /// mirrorLock 内完成「取出即出队 + 计数递增」，watchdog 调用侧原子。
    private func takeNextMirrorCandidate() -> String? {
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        guard mirrorAttempts < Self.mirrorRetryLimit, !mirrorCandidates.isEmpty else {
            return nil
        }
        mirrorAttempts += 1
        return mirrorCandidates.removeFirst()
    }

    /// build 48 · 需求 4：当前已自动切换的镜像次数（诊断文案用）。
    private func currentMirrorAttempts() -> Int {
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        return mirrorAttempts
    }

    /// build 48 · 需求 4：resolve 完成时存档镜像候选链（主选已在服务，
    /// 存剩余备选）并清零切换计数。
    private func storeMirrorChain(_ candidates: [String]) {
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        mirrorCandidates = candidates
        mirrorAttempts = 0
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
                // build 48 · 需求 4：resolve 走候选链接口——主选（首位）照旧
                // 入缓存服务，剩余 backup 镜像存档（storeMirrorChain）供
                // watchdog 零数据超时自动切换；非 B站源恒为单元素链，行为不变。
                let playUrls = try await repository.getPlayUrlCandidates(
                    src: parsed.src, albumId: parsed.albumId, chapterIdx: parsed.chapterIdx,
                    detailPath: self?.currentAlbum?.detailPath)
                guard let playUrl = playUrls.first, !playUrl.isEmpty else {
                    throw URLError(.badServerResponse)
                }
                // 解析结果顺手入缓存（同一章 seek/重开不再重复解析）
                self?.storeResolved(key: cacheKey, url: playUrl)
                self?.storeMirrorChain(Array(playUrls.dropFirst()))
                // build 46 · 反馈 1 增强：resolve 出的直链域名入元信息槽——
                // 失败诊断可见「resolve 到了哪个域」（cn-sh-cc-*/upos-*/akamaized）。
                if let host = URL(string: playUrl)?.host {
                    self?.recordLoaderMeta("resolve · 直链域名 \(host)")
                }
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

    /// build 47 · 真机取证闭环（B站 octet-stream 修复）：B站 CDN 镜像节点对
    /// DASH 音轨回 Content-Type: application/octet-stream（真机 2026-10-28
    /// 证据：play · HTTP 206 application/octet-stream @ upos-sz-mirrorbd.
    /// bilivideo.com），AVPlayer 的 contentInformationRequest 拿到 octet-stream
    /// 按不支持格式拒收 → -12847；沙箱出口拿到的是 video/mp4（云端绿真机红
    /// 的分水岭，沙箱无法复现该形态）。本函数对代理流的原始 MIME 做 B站
    /// CDN 域改写：octet-stream 时按 URL 路径线索映射（.m4s/.m4a → audio/mp4，
    /// .mp4 → video/mp4）；非 B站代理域、非 octet-stream 一律原样返回不越权
    /// 重写。无路径线索时返回原值，由首块数据 ftyp 嗅探兜底
    /// （sniffedBiliMp4Mime，ProxyStreamSessionDelegate.didReceive data）。
    /// 纯静态函数，供单测直接校验改写逻辑（BiliContentTypeRewriteTests）。
    static func rewrittenBiliContentType(originalMime: String?, url: URL?) -> String? {
        guard let original = originalMime,
              original.lowercased() == "application/octet-stream" else { return originalMime }
        guard let url, let host = url.host, ProxiedCdnHosts.needsProxy(host) else { return originalMime }
        let path = url.path.lowercased()
        if path.contains(".m4s") || path.contains(".m4a") { return "audio/mp4" }
        if path.contains(".mp4") { return "video/mp4" }
        return originalMime
    }

    /// build 47 · Content-Type 嗅探兜底：响应期无路径线索的 B站 octet-stream 流，
    /// 首个覆盖流内偏移 4..<8 的数据块若为「ftyp」盒标签即判 fMP4 → audio/mp4
    /// （本 App 仅代理 B站 DASH 音轨，音轨分段一律 audio/mp4）。streamOffset
    /// 为本块首字节的流内偏移（206 按 Content-Range 对齐后），块起点已越过
    /// ftyp 位置（如 moov 段请求自 36 起）则不再嗅探。纯静态函数，供单测
    /// 直接构造 Data 校验嗅探逻辑。
    static func sniffedBiliMp4Mime(data: Data, streamOffset: Int64) -> String? {
        guard streamOffset >= 0, streamOffset <= 4 else { return nil }
        let start = Int(4 - streamOffset)
        guard data.count >= start + 4 else { return nil }
        return data.subdata(in: start..<(start + 4)) == Data("ftyp".utf8) ? "audio/mp4" : nil
    }

    // MARK: - build 48 · 需求 4：watchdog 超时形态判定（纯静态，单测直调）

    /// watchdog 观察窗内视为「有实质进度」的最小转发增量——低于该值说明
    /// 这 20s 内数据实质未前进（≤16KB/20s ≈ 800B/s，该速率下长音频
    /// 《择日飞升》49:38 的初始缓冲永远就绪不了），按挂起处理；
    /// ≥ 该值说明数据在缓慢到达，延长观察（AVFoundation 拿到数据终会
    /// readyToPlay，主动掐掉反而误伤可恢复的缓冲）。16KB ≈ fMP4 init
    /// segment（ftyp+moov）量级——拿到它条目才有就绪的可能。
    static let streamProgressFloorBytes: Int64 = 16 * 1024

    /// 镜像自动重试上限（主选之外最多再试 3 个 backup 镜像；B站 playurl
    /// backup_url 通常 2~3 条，覆盖全部链的同时防异常长链拖播放）。
    static let mirrorRetryLimit = 3

    /// watchdog 到点采样的超时形态判定。纯静态函数（PlaybackManagerTests
    /// 直调），判据与文案口径：
    /// - `progressing`：本观察窗增量 ≥ streamProgressFloorBytes——数据在
    ///   缓慢到达，**不报错不切镜像**，重挂 watchdog 延长观察；
    /// - `stalledNoData`：累计转发为零——「20 秒内零字节到达」真挂起
    ///   （镜像节点死/极慢），首选切 backup_url 镜像重试；
    /// - `stalledAfterData`：先到达部分数据后停滞——「数据中途停滞」，
    ///   同样切镜像（对条目就绪而言停滞与零数据等价，仅诊断文案区分）。
    enum StreamStallVerdict: Equatable {
        case progressing(deltaBytes: Int64)
        case stalledNoData
        case stalledAfterData(forwardedBytes: Int64)
    }

    static func streamStallVerdict(previousBytes: Int64, currentBytes: Int64) -> StreamStallVerdict {
        if currentBytes - previousBytes >= streamProgressFloorBytes {
            return .progressing(deltaBytes: currentBytes - previousBytes)
        }
        return currentBytes <= 0 ? .stalledNoData : .stalledAfterData(forwardedBytes: currentBytes)
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
