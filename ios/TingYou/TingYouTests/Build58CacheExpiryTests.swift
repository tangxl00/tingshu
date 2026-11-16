import XCTest
import Observation
@testable import TingYou

/// build 58 · 「锁屏后台切章加载失败」四项修复的行为级用例（每项 ≥1 条 + 形态守卫）。
///
/// 缺陷三条（b57 行号为准，根因取证见父任务排查结论）：
/// * #1 预取缓存 `resolvedPlayUrls` 无 TTL 无失败清除——锁屏长听数十分钟后切章，
///   命中的是早已过期的 B站签名直链 → 代理取流 403 → 403 不在可重试码集 → 终局报错；
/// * #2 正常切章清空 `mirrorCandidates`，而缓存命中路径跳过 `storeMirrorChain`
///   → 缓存命中那一章取流失败时无镜像可换（`exhausted(attempts: 0)`）；
/// * #3 失败不清缓存 → `retryCurrentChapter()` 反复踩同一条过期地址，重试永远不过。
///
/// 判别力口径：每条行为用例都驱动**生产同一份实现**（`prepareCachedServe` /
/// `handleChapterLoadFailure` / `requestForbiddenSelfHeal` / `rebuildForMirrorRetry`），
/// 用例内不复制缓存或自愈逻辑；「时间」经 `resolveClockMsProvider` 注入推进，
/// 不为过期判定真等 10 分钟。静态守卫一律用声明级 needle 且先剔整行注释。
final class Build58CacheExpiryTests: XCTestCase {

    // MARK: - 工具（与 Build55/57 同构）

    private func isolatedSkipStore() -> SkipSettingsStore {
        let suite = "Build58CacheExpiry-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("无法创建隔离 UserDefaults suite：\(suite)")
            return SkipSettingsStore()
        }
        return SkipSettingsStore(defaults: defaults)
    }

    private func makeAlbum(src: String, albumId: Int64, title: String = "测试书") -> Album {
        Album(albumId: albumId, title: title, author: nil, teller: nil,
              coverUrl: nil, intro: nil, category: nil, categoryId: nil,
              type: nil, typeId: nil, status: nil, chapterCount: nil,
              updatedAt: nil, playCount: nil, available: true,
              source: src, detailPath: nil)
    }

    private func oneBasedChapters(_ n: Int, durationSec: Int? = nil) -> [Chapter] {
        (1...n).map { Chapter(chapterId: Int64($0), index: $0,
                              title: "第\($0)章", durationSec: durationSec) }
    }

    private func waitForHistoryIdle(_ pm: PlaybackManager) async throws {
        for _ in 0..<200 {
            if pm.isHistoryWriteIdle { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("历史排水 1s 内未空闲（isHistoryWriteIdle 恒 false）")
    }

    final class ProbeHistoryRecorder: PlaybackHistoryRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [(chapterTitle: String, positionMs: Int64)] = []
        var writes: [(chapterTitle: String, positionMs: Int64)] {
            lock.lock(); defer { lock.unlock() }
            return _writes
        }
        func recordHistory(album: Album, chapter: Chapter,
                           positionMs: Int64, durationMs: Int64) async {
            lock.lock()
            _writes.append((chapter.title, positionMs))
            lock.unlock()
        }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// B站占位 URI（代理域签名直链的唯一入口，`isBiliOwnerKey` 的判据来源）。
    private func biliKey(albumId: Int64 = 9001, chapterIdx: Int = 0) -> String {
        PlayUri.build(src: SourceRegistry.BILI, albumId: albumId, chapterIdx: chapterIdx)
    }

    private func tingyouKey(albumId: Int64 = 9002, chapterIdx: Int = 0) -> String {
        PlayUri.build(src: SourceRegistry.TINGYOU, albumId: albumId, chapterIdx: chapterIdx)
    }

    /// 一条真实的 B站代理域直链形状（域名命 `ProxiedCdnHosts.needsProxy`）。
    private static let biliUrl = "https://upos-sz-mirrorcos.bilivideo.com/audio/x.m4s?sig=deadbeef"
    private static let biliMirror1 = "https://upos-sz-mirrorali.bilivideo.com/audio/x.m4s?sig=deadbeef"
    private static let biliMirror2 = "https://cn-sh-cc-01.akamaized.net/audio/x.m4s?sig=deadbeef"
    /// 非代理域直链（tingyou redirect 直链形状）。
    private static let tingyouUrl = "https://aod.cos.tx.xmcdn.com/audio/x.m4a"

    // MARK: - 修复 1 · 缓存时效（B站签名直链超阈值强制现解析）

    /// 行为级（旧实现必红）：注入时钟把「解析时刻」推过阈值，
    /// `prepareCachedServe` 必须返回 nil（落到现解析），且条目被**真的删除**——
    /// 把时钟拨回新鲜时刻仍是 nil。若不删、只是「不服务」，第二条断言会假绿。
    @MainActor
    func testExpiredBiliCacheIsNotServedAndEntryIsRemoved() throws {
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        let key = biliKey()
        let t0 = Self.nowMs()
        pm.seedResolvedCacheForTesting(key: key, url: Self.biliUrl, resolvedAtMs: t0)

        // 前置：新鲜态可命中（否则后面的「过期」断言没有对照）
        pm.resolveClockMsProvider = { t0 + 60_000 }
        XCTAssertEqual(pm.prepareCachedServe(forKey: key), Self.biliUrl,
                       "前置：TTL 内的 B站直链必须命中缓存（切章零等待的收益不得被砍掉）")

        // 超过 10 分钟阈值 → 不服务
        pm.resolveClockMsProvider = { t0 + PlaybackManager.biliSignedUrlCacheTTLMs + 1_000 }
        XCTAssertNil(pm.prepareCachedServe(forKey: key),
                     "超过 biliSignedUrlCacheTTLMs 的 B站直链必须判过期、不服务缓存（修复 1 的判别点）")

        // 条目已删除：把时钟拨回 TTL 内，仍拿不到（证明「清除」而非「本次不读」）
        pm.resolveClockMsProvider = { t0 + 60_000 }
        XCTAssertNil(pm.prepareCachedServe(forKey: key),
                     "过期条目必须被移除（否则时钟回拨仍会命中，等于把过期地址留着踩）")
    }

    /// 行为级：非代理域（tingyou redirect 直链）**不设 TTL**——同样老的条目仍命中。
    /// 理由见 TTL 注释：redirect 直链无 deadline 语义，且该分支没有取流拒绝的观测点。
    @MainActor
    func testNonBiliCacheIgnoresTtl() throws {
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        let key = tingyouKey()
        let t0 = Self.nowMs()
        pm.seedResolvedCacheForTesting(key: key, url: Self.tingyouUrl, resolvedAtMs: t0)
        pm.resolveClockMsProvider = { t0 + PlaybackManager.biliSignedUrlCacheTTLMs * 6 }
        XCTAssertEqual(pm.prepareCachedServe(forKey: key), Self.tingyouUrl,
                       "非 B站 redirect 直链没有签名过期语义，不得套用 B站 TTL（否则把可用直链判死）")
    }

    /// 纯函数三态（生产与用例共用）：只对代理域直链限时。
    func testIsCacheEntryExpiredOnlyAppliesToProxiedHosts() {
        let t0: Int64 = 1_700_000_000_000
        let ttl = PlaybackManager.biliSignedUrlCacheTTLMs
        XCTAssertFalse(PlaybackManager.isCacheEntryExpired(
            .init(url: Self.biliUrl, resolvedAtMs: t0), nowMs: t0 + ttl),
            "恰好等于阈值不得判过期（边界取「超过」而非「达到」）")
        XCTAssertTrue(PlaybackManager.isCacheEntryExpired(
            .init(url: Self.biliUrl, resolvedAtMs: t0), nowMs: t0 + ttl + 1),
            "超过阈值必须判过期")
        XCTAssertFalse(PlaybackManager.isCacheEntryExpired(
            .init(url: Self.tingyouUrl, resolvedAtMs: t0), nowMs: t0 + ttl * 100),
            "非代理域直链任何年龄都不得判过期")
    }

    // MARK: - 修复 2 · 失败即淘汰（手动重试走现解析，不再踩同一过期地址）

    /// 行为级（旧实现必红）：取流被拒（非 2xx，`.failed` 同路径）后该章缓存条目必须消失。
    @MainActor
    func testLoadFailureInvalidatesCacheSoRetryReResolves() throws {
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        let key = tingyouKey()
        let t0 = Self.nowMs()
        pm.resolveClockMsProvider = { t0 + 60_000 }
        pm.seedResolvedCacheForTesting(key: key, url: Self.tingyouUrl, resolvedAtMs: t0)
        XCTAssertEqual(pm.prepareCachedServe(forKey: key), Self.tingyouUrl, "前置：缓存可命中")

        pm.handleChapterLoadFailure(ownerKey: key, statusCode: 500, sourceHost: "aod.cos.tx.xmcdn.com")
        XCTAssertNil(pm.prepareCachedServe(forKey: key),
                     "取流被拒后该章缓存必须被清除（否则「重试」再命中同一条坏地址 → 永远重试不过）")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 0,
                       "非 403 / 非 B站源的失败不得触发自愈（4xx/5xx 不盲换镜像的原则保持）")
    }

    /// 行为级：`item .failed` 通道（statusCode 为 nil）同样清缓存。
    @MainActor
    func testItemFailedWithoutStatusAlsoInvalidatesCache() throws {
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        let key = biliKey(albumId: 9003)
        let t0 = Self.nowMs()
        pm.resolveClockMsProvider = { t0 + 60_000 }
        pm.seedResolvedCacheForTesting(key: key, url: Self.biliUrl, resolvedAtMs: t0)
        XCTAssertEqual(pm.prepareCachedServe(forKey: key), Self.biliUrl, "前置：缓存可命中")

        pm.handleChapterLoadFailure(ownerKey: key, statusCode: nil, sourceHost: nil)
        XCTAssertNil(pm.prepareCachedServe(forKey: key),
                     "item .failed（无 HTTP 状态）也必须清缓存——这条路径覆盖 CDN/网络层失败")
    }

    // MARK: - 修复 3 · 缓存命中补装镜像链

    /// 行为级（旧实现必红）：缓存命中后 `mirrorCandidates` 必须非空（有 backup 可换）。
    /// 旧实现命中即服务、跳过 `storeMirrorChain` → 候选恒 0 → 切章失败只能报
    /// 「无可用 backup 镜像」。
    @MainActor
    func testCacheHitRestoresMirrorChain() throws {
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        let key = biliKey(albumId: 9004)
        let t0 = Self.nowMs()
        pm.resolveClockMsProvider = { t0 + 60_000 }
        pm.seedResolvedCacheForTesting(
            key: key, url: Self.biliUrl,
            mirrors: [Self.biliMirror1, Self.biliMirror2], resolvedAtMs: t0)
        XCTAssertEqual(pm.mirrorCandidatesCountForTesting, 0, "前置：装链前候选为空")

        XCTAssertEqual(pm.prepareCachedServe(forKey: key), Self.biliUrl, "前置：缓存命中")
        XCTAssertEqual(pm.mirrorCandidatesCountForTesting, 2,
                       "缓存命中必须补装镜像链（修复 3 的判别点：旧实现恒 0 条）")
        XCTAssertEqual(pm.mirrorAttemptsForTesting, 0, "补链必须清零已切换次数（新一轮装载）")
    }

    /// 行为级：过期链不得装回去——把同批解析时刻推过阈值，候选仍为 0。
    /// 理由：镜像与主选同批解析、同批过期，装一条同样 403 的地址只是浪费切换额度。
    @MainActor
    func testExpiredMirrorChainIsNotRestored() throws {
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        let key = biliKey(albumId: 9005)
        let t0 = Self.nowMs()
        // 主选新鲜（非代理域，不受 TTL），链里带代理域候选且时刻很旧
        pm.seedResolvedCacheForTesting(key: key, url: Self.tingyouUrl, mirrors: nil, resolvedAtMs: t0)
        XCTAssertEqual(pm.prepareCachedServe(forKey: key), Self.tingyouUrl, "前置：主选可命中")

        let expiredChain = PlaybackManager.MirrorChainEntry(
            candidates: [Self.biliMirror1], resolvedAtMs: t0)
        XCTAssertTrue(PlaybackManager.isMirrorChainExpired(
            expiredChain, nowMs: t0 + PlaybackManager.biliSignedUrlCacheTTLMs + 1),
            "含代理域候选且超阈值的链必须判过期")
        XCTAssertFalse(PlaybackManager.isMirrorChainExpired(
            expiredChain, nowMs: t0 + 60_000), "TTL 内的链必须可用")
        XCTAssertFalse(PlaybackManager.isMirrorChainExpired(
            .init(candidates: [Self.tingyouUrl], resolvedAtMs: t0),
            nowMs: t0 + PlaybackManager.biliSignedUrlCacheTTLMs * 10),
            "全非代理域候选的链不得因时间被判过期（与直链口径一致）")
    }

    // MARK: - 修复 4 · B站 403 = 过期信号 → 一次性自愈

    /// 行为级（旧实现必红）：静默装载态下 B站 403 必须触发一次自愈（计数 0→1），
    /// 且**不得解除抑制、不得写历史**（b55–b57 闸门硬约束）。
    /// 自愈复用 `rebuildForMirrorRetry()`（镜像重建唯一生产入口，内部透传 silentWrite）。
    @MainActor
    func testBili403SelfHealsOnceAndKeepsSilentSemantics() async throws {
        let album = makeAlbum(src: SourceRegistry.BILI, albumId: 9006)
        let chapters = oneBasedChapters(6, durationSec: 1_500)
        let recorder = ProbeHistoryRecorder()
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        pm.historyRecorder = recorder
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(0), startPosMs: 120_000, silentWrite: true)
        XCTAssertTrue(pm.historyWriteSuppressed, "前置：静默装载必须处于抑制态")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 0, "前置：静默装载零历史写入")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 0, "前置：尚未自愈")

        let key = PlayUri.build(src: album.source, albumId: album.albumId,
                               chapterIdx: chapters[0].index)
        pm.handleChapterLoadFailure(ownerKey: key, statusCode: 403,
                                    sourceHost: "upos-sz-mirrorcos.bilivideo.com")

        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 1,
                       "B站 403 必须触发一次自愈（修复 4 的判别点：旧实现直接终局报错）")
        XCTAssertTrue(pm.historyWriteSuppressed,
                      "自愈重装载不得解除抑制（b56 P1-A 闸门零回退：静默态必须仍静默）")
        try await waitForHistoryIdle(pm)
        XCTAssertEqual(recorder.writes.count, 0,
                       "静默态的自愈重装载不得误写历史（否则顶 updatedAt + outbox 污染云端）")
        XCTAssertEqual(pm.currentPositionMs, 120_000,
                       "自愈重装载必须沿用装载目标位置（镜像重建的 P2-2 语义不得回退）")
    }

    /// 行为级（防 403 风暴）：同一章第二次 403 不再自愈，计数保持 1，且缓存仍被清。
    @MainActor
    func testSecondBili403DoesNotSelfHealAgain() throws {
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        let album = makeAlbum(src: SourceRegistry.BILI, albumId: 9007)
        let chapters = oneBasedChapters(4, durationSec: 1_500)
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(0), startPosMs: 0, silentWrite: false)
        let key = PlayUri.build(src: album.source, albumId: album.albumId,
                               chapterIdx: chapters[0].index)

        pm.handleChapterLoadFailure(ownerKey: key, statusCode: 403, sourceHost: "bilivideo.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 1, "第一次 403 自愈一次")
        pm.handleChapterLoadFailure(ownerKey: key, statusCode: 403, sourceHost: "bilivideo.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 1,
                       "同一章第二次 403 不得再自愈（只自愈一次，防 playurl 请求风暴 + 412 风控）")
    }

    /// 行为级：用户主动装载（非镜像重建）开新的一轮 → 自愈记账作废，
    /// 「手动重试」仍能拿到一次自愈机会（不能因一次失败就永久放弃该章）。
    @MainActor
    func testManualReloadResetsSelfHealLedger() throws {
        let album = makeAlbum(src: SourceRegistry.BILI, albumId: 9008)
        let chapters = oneBasedChapters(4, durationSec: 1_500)
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(0), startPosMs: 0, silentWrite: false)
        let key = PlayUri.build(src: album.source, albumId: album.albumId,
                               chapterIdx: chapters[0].index)
        pm.handleChapterLoadFailure(ownerKey: key, statusCode: 403, sourceHost: "bilivideo.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 1)

        // 用户点「重试」= 非 keepMirrorChain 的主动装载（走生产入口 retryCurrentChapter）
        pm.retryCurrentChapter()
        pm.handleChapterLoadFailure(ownerKey: key, statusCode: 403, sourceHost: "bilivideo.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 2,
                       "用户主动重试开启新一轮，必须重新获得一次自愈机会（否则该章永久终局）")
    }

    /// 行为级：非 B站源 403 不自愈（维持「4xx/5xx 不盲换镜像」的既有原则）。
    @MainActor
    func testNonBili403DoesNotSelfHeal() throws {
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        let album = makeAlbum(src: SourceRegistry.TINGYOU, albumId: 9009)
        let chapters = oneBasedChapters(4, durationSec: 1_500)
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(0), startPosMs: 0, silentWrite: false)
        let key = PlayUri.build(src: album.source, albumId: album.albumId,
                               chapterIdx: chapters[0].index)
        pm.handleChapterLoadFailure(ownerKey: key, statusCode: 403, sourceHost: "aod.cos.tx.xmcdn.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 0,
                       "非 B站源没有「签名过期」语义，403 维持现状直接终局（不得盲自愈）")
    }

    // MARK: - 形态守卫（声明级 needle + 剔整行注释）

    func testCacheAndFailurePathsAreWiredInProduction() throws {
        let code = Self.codeOnly(try Self.source("TingYou/Playback/PlaybackManager.swift"))

        // 修复 1：命中路径必须判时效（走生产唯一读取实现）
        let prepare = Self.functionBody(of: code, needle: "func prepareCachedServe")
        XCTAssertFalse(prepare.isEmpty, "必须截到 prepareCachedServe 函数体")
        XCTAssertTrue(prepare.contains("resolvedPlayUrl(forKey: key)"),
                      "缓存命中必须经带时效的读取实现（修复 1 的唯一读取入口）")
        let readBody = Self.functionBody(of: code, needle: "private func resolvedPlayUrl")
        XCTAssertTrue(readBody.contains("isCacheEntryExpired"),
                      "读取实现必须调用过期判定（否则 TTL 形同虚设）")
        XCTAssertTrue(readBody.contains("resolvedPlayUrls.removeValue(forKey: key)"),
                      "过期条目必须被移除（不是仅本次不服务）")

        // 修复 3：命中补链
        XCTAssertTrue(prepare.contains("restoreMirrorChainFromCache"),
                      "缓存命中必须补装镜像链（修复 3 的接线点）")
        XCTAssertTrue(code.contains("mirrors: Array(playUrls.dropFirst())"),
                      "解析结果必须把剩余候选随条目入缓存（否则命中时无链可补）")
        let deny = Self.functionBody(of: code, needle: "func restoreMirrorChainFromCache")
        XCTAssertTrue(deny.contains("isMirrorChainExpired"),
                      "过期镜像链不得装回（同批解析同批过期）")

        // 修复 2/4：失败路径清缓存 + 403 自愈，且顺序「先清后愈」
        let failure = Self.functionBody(of: code, needle: "func handleChapterLoadFailure")
        XCTAssertFalse(failure.isEmpty, "必须截到 handleChapterLoadFailure 函数体")
        guard let invalidateIdx = failure.range(of: "invalidateResolvedUrl")?.lowerBound,
              let healIdx = failure.range(of: "requestForbiddenSelfHeal")?.lowerBound else {
            XCTFail("失败处理实现必须同时含清缓存与 403 自愈两个调用")
            return
        }
        XCTAssertTrue(failure.distance(from: invalidateIdx, to: healIdx) > 0,
                      "必须先清缓存再自愈（自愈重装载要落到现解析，缓存不清就又会命中过期地址）")
        XCTAssertTrue(failure.contains("statusCode == 403"), "自愈必须以 403 为触发条件")
        XCTAssertTrue(failure.contains("isBiliOwnerKey"), "自愈必须限定 B站源（非 B站维持现状）")

        // 修复 2 的第二条通道：取流被拒守卫里的结构化拒绝信号必须早于 finishLoading
        guard let denyCall = code.range(of: "denialRecorder?(")?.lowerBound else {
            XCTFail("非 2xx 守卫必须发出结构化拒绝信号")
            return
        }
        let afterDeny = code[denyCall...]
        guard let finishCall = afterDeny.range(of: "request.finishLoading(with:")?.lowerBound else {
            XCTFail("拒绝信号后必须有 finishLoading（取流失败终局路径）")
            return
        }
        let between = afterDeny[..<finishCall]
        XCTAssertLessThan(between.filter { $0 == "\n" }.count, 200,
                          "拒绝信号必须在 finishLoading 之前发出（finishLoading 会触发 .failed，届时缓存已清）")

        // 修复 4：自愈重装载仍走镜像重建唯一生产入口（静默态透传）
        let healBody = Self.functionBody(of: code, needle: "func requestForbiddenSelfHeal")
        XCTAssertTrue(healBody.contains("rebuildForMirrorRetry()"),
                      "自愈必须复用镜像重建唯一生产入口（另写一套会漏传 silentWrite）")
        XCTAssertTrue(healBody.contains("forbiddenSelfHealKeys.contains"),
                      "自愈必须按章记账（只自愈一次）")
        let rebuild = Self.functionBody(of: code, needle: "func rebuildForMirrorRetry")
        XCTAssertTrue(rebuild.contains("silentWrite: self.historyWriteSuppressed"),
                      "镜像重建仍必须透传当前抑制态（b56 P1-A 零回退）")
    }

    /// b55–b57 闸门体系标识符逐一核验（零回退硬约束）。
    func testHistoryGateIdentifiersUnchanged() throws {
        let code = Self.codeOnly(try Self.source("TingYou/Playback/PlaybackManager.swift"))
        XCTAssertEqual(code.components(separatedBy: "guard !historyWriteSuppressed").count - 1, 1,
                       "recordHistory 入口闸门必须唯一（b55 P1-2）")
        let releaseCalls = code.split(separator: "\n").filter {
            $0.contains("releaseHistorySuppression()") && !$0.contains("private func")
        }
        XCTAssertEqual(releaseCalls.count, 2,
                       "releaseHistorySuppression 全库必须恰 2 处调用（b56 P1-A 零回退）")
        XCTAssertTrue(code.contains("} else if !keepMirrorChain {"),
                      "闸门分支必须仍是 else if !keepMirrorChain（镜像重建不解除抑制）")
        let rebuild = Self.functionBody(of: code, needle: "func rebuildForMirrorRetry")
        XCTAssertTrue(rebuild.contains("silentWrite: self.historyWriteSuppressed"),
                      "rebuildForMirrorRetry 仍是镜像重建唯一生产入口的内部透传点")
    }

    // MARK: - 工具：源码读取 / 剔注释 / 截函数体

    private static func source(_ rel: String) throws -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("\(rel) 不存在：\(path)——路径布局变化时请同步修正本测试")
            throw NSError(domain: "Build58CacheExpiryTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing source \(rel)"])
        }
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(rel) 不可读：\(path)")
            throw NSError(domain: "Build58CacheExpiryTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "unreadable source \(rel)"])
        }
        return src
    }

    private static func codeOnly(_ src: String) -> String {
        src.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func functionBody(of code: String, needle: String) -> String {
        let lines = code.split(separator: "\n").map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(needle) }) else { return "" }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.isFunctionDeclarationLine(trimmed) && !body.isEmpty { break }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }

    private static func isFunctionDeclarationLine(_ trimmed: String) -> Bool {
        let modifiers = ["", "private ", "fileprivate ", "internal ", "public ",
                         "override ", "final ", "static ", "private static ",
                         "fileprivate static ", "class "]
        return modifiers.contains { mod in
            trimmed.hasPrefix(mod + "func ") || trimmed.hasPrefix(mod + "deinit {")
        }
    }
}
