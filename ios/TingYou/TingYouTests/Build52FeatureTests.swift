import XCTest
import SwiftData
@testable import TingYou

/// build 52 · #140 复检四条放行条件的行为级回归守卫。
///
/// 与 b51 的差异（#140 条件 3 明确点名）：b51 的 P1-2 / P1-3 守卫是**字符串扫描**
/// （`engine.contains("case \"success\", \"duplicate\", \"ok\":")`），源码改法一换就
/// 失效、也证明不了任何运行期行为。本文件全部走**真实同步流程**：
/// 用 `RetryStubURLProtocol` 注入云端响应，构造 `SyncEngine` 真跑 `syncNow` /
/// `onSyncPageEnter`，断言 outbox 条数、`lastSyncAtMs`、`lastSeq`、续期状态这些
/// 可观察结果。
///
/// 条件对照：
/// - 条件 1 → `testRenewalTransientFailureNotDisguisedAsRefreshing` /
///            `testRenewalTerminalFailureDemotesToLoggedOut`
/// - 条件 2 → `testExpiredTokenPendingOutboxClearsWithoutAnyTap` /
///            `testTransientFailureAutoRetriesUntilSuccessWithoutAnyTap`
/// - 条件 3 → `testPushFailedItemStaysInOutboxAndDoesNotMarkSuccess` /
///            `testMergeSaveFailureDoesNotAdvanceLastSeq` / `testBackoffLadder`
final class Build52FeatureTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SyncLocalStore!

    override func setUp() async throws {
        try await super.setUp()
        RetryStubURLProtocol.reset()
        suiteName = "b52-sync-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SyncLocalStore(defaults: defaults)
    }

    override func tearDown() async throws {
        RetryStubURLProtocol.reset()
        defaults?.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - 条件 2 · token 过期 + outbox 有待传条目 → 不点任何按钮自动清零

    /// 真机故障场景的验收口径（#140 条件 2 原文）：token 已过期、outbox 有待补传
    /// 条目，进同步页（`onSyncPageEnter`，等价界面 `.task`）**不点任何按钮**，
    /// 待补传数必须自动清零。
    ///
    /// b51 不满足的原因同样在此被固化：同步页没有任何 `syncNow` 触发点、
    /// `accessExpireAtMs` 全仓零读取，所以这条路径在 b51 上根本不存在。
    @MainActor
    func testExpiredTokenPendingOutboxClearsWithoutAnyTap() async throws {
        login(accessExpiresInMs: -60_000)          // 令牌已过期 60s
        enqueueFavorite(albumId: 7001)
        let opId = store.loadOutbox()[0].clientOpId
        XCTAssertEqual(store.outboxCount, 1, "前置：outbox 必须有 1 条待补传")

        var refreshed = false
        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "auth/v1/refresh":
                refreshed = true
                return Self.ok(Self.refreshJSON(token: "atk-new"))
            case "sync/v1/push":
                // 旧令牌被拒 40003；续期后的新令牌照常受理
                return refreshed ? Self.ok(Self.pushJSON(results: [(opId, "success")]))
                                 : Self.err(40003, "access token expired")
            case "sync/v1/pull":
                return Self.ok(Self.pullJSON(serverSeq: 11, favorites: [], progress: []))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }

        let engine = makeEngine()
        XCTAssertTrue(engine.needsProactiveRenewal(),
                      "前置：令牌已过期必须进入提前续期窗口（accessExpireAtMs 真实读取点）")

        await engine.onSyncPageEnter()             // ← 进页自动触发，全程无按钮
        await drain(engine)

        XCTAssertEqual(store.outboxCount, 0, "待补传必须自动清零（条件 2 验收口径）")
        XCTAssertEqual(engine.pendingOps, 0, "界面绑定的待补传数必须同步归零")
        XCTAssertGreaterThan(engine.lastSyncAtMs, 0, "成功后必须记录上次同步时间")
        XCTAssertEqual(engine.renewalState, .idle, "成功路径不得残留任何续期告警")
        XCTAssertEqual(engine.syncFailure, .none, "成功路径不得残留任何同步失败告警")
        XCTAssertEqual(engine.phase, .loggedIn, "成功路径必须保持登录态")
    }

    /// 条件 2 的更难一档：**续期第一次就失败**（网络瞬态），仍不点任何按钮，
    /// 由退避重试自愈到清零。这条直接对应「红字 + 待补传 1 条恒挂 3.5h」的反面。
    @MainActor
    func testTransientFailureAutoRetriesUntilSuccessWithoutAnyTap() async throws {
        login(accessExpiresInMs: 10 * 60_000)      // 令牌有效 → 走 withAuth 的 40003 分支
        enqueueFavorite(albumId: 7002)
        let opId = store.loadOutbox()[0].clientOpId
        XCTAssertEqual(store.outboxCount, 1)

        var didRefresh = false
        var pushCalls = 0
        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/push":
                pushCalls += 1
                return didRefresh ? Self.ok(Self.pushJSON(results: [(opId, "success")]))
                                  : Self.err(40003, "access token expired")
            case "auth/v1/refresh":
                didRefresh = true
                return Self.ok(Self.refreshJSON(token: "atk-new"))
            case "sync/v1/pull":
                return Self.ok(Self.pullJSON(serverSeq: 12, favorites: [], progress: []))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        // 首次续期请求注入传输层瞬态（真实 URLError，而不是被重包的 40003）。
        // 必须在发请求**之前**装好 matcher：URLProtocol.startLoading 先查 matcher
        // 再走 handler，在 handler 里装只能命中「下一次」，首次请求反而会成功。
        let refreshAttempts = AttemptCounter()
        RetryStubURLProtocol.errorMatcher = { req in
            guard Self.path(req) == "auth/v1/refresh" else { return nil }
            if refreshAttempts.next() == 1 { return URLError(.timedOut) }
            return nil
        }

        let engine = makeEngine()
        engine.retryBackoffOverride = [.milliseconds(60), .milliseconds(120)]

        await engine.syncNow()                     // 第 1 轮：续期失败 → 挂重试
        XCTAssertEqual(store.outboxCount, 1, "瞬态失败时变更必须仍在队列（不得静默丢）")
        XCTAssertTrue(engine.renewalState.isRetrying, "瞬态失败必须落到「稍后自动重试」")
        XCTAssertGreaterThanOrEqual(pushCalls, 1, "前置：首轮必须真的推过（否则下面等于空测）")

        // 退避重试由引擎自己驱动，测试只等结果，不再手动调 syncNow
        var waited = 0
        while store.outboxCount > 0 && waited < 60 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }

        XCTAssertEqual(store.outboxCount, 0, "瞬态失败后必须自动重试到清零（无需用户点按钮）")
        XCTAssertGreaterThan(engine.lastSyncAtMs, 0, "重试成功必须记上次同步时间")
        XCTAssertEqual(engine.renewalState, .idle, "自愈后不得残留告警")
        XCTAssertEqual(engine.syncFailure, .none, "自愈后同步维度也不得残留告警")
        XCTAssertEqual(engine.retryAttempt, 0, "成功后退避计数必须归零")
    }

    // MARK: - 条件 1 · 续期失败的语义不得伪装成「进行中」

    /// #140 条件 1 的根因固化：续期遇到非 40002 异常时，原实现把它重包成
    /// `SyncCloudError(40003)`，而 40003 文案是「…正在自动续期」——终局失败被
    /// 渲染成进行中。
    ///
    /// 断言语义（不扫字面量）：瞬态失败后
    /// - 必须落到 `.retryScheduled`（可自动恢复），**不得**停在 `.refreshing`
    ///   （停在 refreshing 就是「红字挂 3.5h 不动」的形态）；
    /// - 不得进入 `.terminal`（凭据必须保留，用户无需重新登录）；
    /// - 告警文案必须写「未成功」而不是「正在」。
    @MainActor
    func testRenewalTransientFailureNotDisguisedAsRefreshing() async throws {
        login(accessExpiresInMs: 10 * 60_000)
        enqueueFavorite(albumId: 7003)

        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/push":
                return Self.err(40003, "access token expired")
            case "auth/v1/refresh":
                return Self.ok(Self.refreshJSON(token: "unused"))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        // 续期这次请求一律传输层失败（真实 URLError，不是被重包的 40003）。
        // matcher 在发请求前装好，才能命中**本次**续期请求。
        RetryStubURLProtocol.errorMatcher = { req in
            guard Self.path(req) == "auth/v1/refresh" else { return nil }
            return URLError(.timedOut)
        }
        let engine = makeEngine()
        engine.retryBackoffOverride = [.seconds(600)]   // 只观察状态，不让重试真跑
        await engine.syncNow()

        guard case .retryScheduled(let text) = engine.renewalState else {
            return XCTFail("瞬态续期失败必须落到 .retryScheduled，实际 \(engine.renewalState)")
        }
        XCTAssertFalse(engine.renewalState.isTerminal, "网络瞬态不是终局，不得要求重新登录")
        XCTAssertTrue(text.contains("未成功"),
                      "瞬态失败文案必须如实写「未成功」，不得写「正在」：\(text)")
        XCTAssertFalse(text.contains(SyncEngine.refreshingHeadline),
                       "进行中文案「\(SyncEngine.refreshingHeadline)」只允许出现在真的进行中：\(text)")
        XCTAssertEqual(engine.phase, .loggedIn, "瞬态失败必须保留凭据（否则用户被无故登出）")
        XCTAssertNotNil(store.loadCredentials(), "瞬态失败不得清凭据")
        XCTAssertEqual(store.outboxCount, 1, "失败时变更必须留在队列")
        XCTAssertEqual(engine.lastSyncAtMs, 0, "未完成的一轮不得刷新「上次同步成功」")
        engine.stopRetry()
    }

    /// 终局分支：refresh 回 40002（refresh_token 失效）→ 必须清凭据回未登录，
    /// 并给出「请重新登录」的终局态，而不是继续显示「正在续期」。
    @MainActor
    func testRenewalTerminalFailureDemotesToLoggedOut() async throws {
        login(accessExpiresInMs: 10 * 60_000)
        enqueueFavorite(albumId: 7004)

        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/push":
                return Self.err(40003, "access token expired")
            case "auth/v1/refresh":
                return Self.err(40002, "refresh token invalid")
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        let engine = makeEngine()
        await engine.syncNow()

        XCTAssertEqual(engine.phase, .loggedOut, "40002 必须回未登录态")
        XCTAssertNil(store.loadCredentials(), "终局失败必须清凭据（凭据留着只会继续撞 40003）")
        guard case .terminal(let text) = engine.renewalState else {
            return XCTFail("40002 必须落到 .terminal，实际 \(engine.renewalState)")
        }
        XCTAssertTrue(text.contains("重新登录"), "终局文案必须明确引导重新登录：\(text)")
        XCTAssertFalse(engine.renewalState.isRetrying, "终局不得再挂自动重试（点了也不会好）")
        XCTAssertNil(engine.retryTaskForTesting, "终局必须停掉重试任务")
    }

    // MARK: - 条件 3 · push 部分失败 / save 抛错的行为级断言

    /// #140 条件 3 原文：构造含 `failed` 条目的 `SyncPushData` 走**完整 syncNow**
    /// 流程，断言行为。原来只扫 `case "success", "duplicate", "ok":` 字面量。
    ///
    /// 断言：
    /// - 服务端判 failed 的 op **必须留在 outbox**（不得静默丢）；
    /// - `lastPushFailedCount` 计数正确；
    /// - `lastSyncAtMs` **不得**刷新（#140 另一处：syncNow 无条件刷新是错的）；
    /// - 状态必须是「未完成 / 稍后重试」，不得是成功态。
    @MainActor
    func testPushFailedItemStaysInOutboxAndDoesNotMarkSuccess() async throws {
        login(accessExpiresInMs: 10 * 60_000)
        enqueueFavorite(albumId: 7101, title: "会失败的书")
        enqueueFavorite(albumId: 7102, title: "会成功的书")
        let ops = store.loadOutbox()
        XCTAssertEqual(ops.count, 2, "前置：两条待传")

        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/push":
                // 服务端受理 2 条，1 条判 failed（契约 status 字段）
                return Self.ok(Self.pushJSON(results: [
                    (ops[0].clientOpId, "failed"),
                    (ops[1].clientOpId, "success"),
                ]))
            case "sync/v1/pull":
                return Self.ok(Self.pullJSON(serverSeq: 21, favorites: [], progress: []))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        let engine = makeEngine()
        engine.retryBackoffOverride = [.seconds(600)]
        await engine.syncNow()

        XCTAssertEqual(store.outboxCount, 1, "只有 success 的 op 可出队，failed 必须留队")
        XCTAssertEqual(store.loadOutbox().first?.clientOpId, ops[0].clientOpId,
                       "留在队里的必须正是被判 failed 的那条")
        XCTAssertEqual(engine.lastPushFailedCount, 1, "failed 计数必须为 1")
        XCTAssertEqual(engine.lastSyncAtMs, 0,
                       "push 部分失败时不得刷新「上次同步成功」（#140 条件 3 点名修复点）")
        // build 53 · P1-3：push 部分失败属**同步维度**，不得写进续期维度
        XCTAssertTrue(engine.syncFailure.isRetrying,
                      "部分失败必须落到「稍后自动重试」，不得显示成功")
        XCTAssertEqual(engine.renewalState, .idle,
                       "push 部分失败与令牌续期无关，续期维度必须保持 idle（b52 误用同一通道）")
        engine.stopRetry()
    }

    /// #140 条件 3 原文：注入 `save()` 抛错，断言 `lastSeq` **不推进**（部分失败
    /// 不得记成功）。b51 只有字符串扫描，证明不了这条。
    ///
    /// `mergeCommit` 是 build 52 新增的落库接缝：生产路径仍是 `try ctx.save()`，
    /// 用例注入抛错闭包，等价「SwiftData 落库失败」。
    @MainActor
    func testMergeSaveFailureDoesNotAdvanceLastSeq() async throws {
        let container = try ModelContainer(
            for: FavoriteModel.self, HistoryModel.self,
            ImportedBookModel.self, ImportedChapterModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        login(accessExpiresInMs: 10 * 60_000)
        store.lastSeq = 5

        let favoriteRow: [String: Any] = [
            "book_key": "tingyou:8801", "source": "tingyou", "title": "云端书",
            "added_at": 1_700_000_000_000, "last_client_at": 1_700_000_000_000,
        ]
        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/push":
                return Self.ok(#"{"server_seq":5,"results":[],"processed":0,"submitted":0}"#)
            case "sync/v1/pull":
                // 拉到一条收藏变更 & 服务端游标推进到 9
                return Self.ok(Self.pullJSON(serverSeq: 9, favorites: [favoriteRow], progress: []))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        let engine = makeEngine(modelContext: container.mainContext)
        engine.retryBackoffOverride = [.seconds(600)]
        engine.mergeCommit = { _ in
            throw NSError(domain: "B52", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "save boom"])
        }
        await engine.syncNow()

        XCTAssertEqual(store.lastSeq, 5,
                       "落库失败不得推进游标（否则 next since 越过这批变更、数据永久丢）")
        XCTAssertEqual(engine.lastSyncAtMs, 0, "落库失败的一轮不得记成功")
        XCTAssertNotNil(engine.lastMessage, "落库失败必须有明确文案（不得静默）")
        // build 53 · P1-3：落库失败属**同步维度**
        XCTAssertTrue(engine.syncFailure.isRetrying, "落库失败属可恢复，必须挂重试")
        XCTAssertEqual(engine.renewalState, .idle, "落库失败与续期无关，续期维度必须保持 idle")
        XCTAssertFalse(engine.syncing, "本轮结束必须复位 syncing")
        engine.stopRetry()

        // 对照组：解除注入 → 同一批变更必须落库且游标推进（证明上面的失败来自注入点）
        store.lastSeq = 5
        engine.mergeCommit = nil
        // 注：不重置 retryAttempt（private(set)，测试不可写）——syncNow 的成败
        // 不依赖该计数，它只影响后续 scheduleRetry 的退避档位。
        await engine.syncNow()
        XCTAssertEqual(store.lastSeq, 9, "正常落库后游标必须推进到服务端 server_seq")
        XCTAssertGreaterThan(engine.lastSyncAtMs, 0, "全部成功才记上次同步时间")
    }

    /// 退避阶梯（纯函数）：30s → 2m → 10m，超出阶梯钳到最后一档，负数按第 0 档。
    /// `backoffDelay` / `retryBackoff` 在 @MainActor 类上，静态成员同样隔离，
    /// 本用例必须 @MainActor 才能在 Swift 5 模式下通过隔离检查。
    @MainActor
    func testBackoffLadder() {
        let ladder: [Duration] = [.seconds(30), .seconds(120), .seconds(600)]
        XCTAssertEqual(SyncEngine.backoffDelay(forAttempt: 0, using: ladder), .seconds(30))
        XCTAssertEqual(SyncEngine.backoffDelay(forAttempt: 1, using: ladder), .seconds(120))
        XCTAssertEqual(SyncEngine.backoffDelay(forAttempt: 2, using: ladder), .seconds(600))
        XCTAssertEqual(SyncEngine.backoffDelay(forAttempt: 9, using: ladder), .seconds(600),
                       "超出阶梯必须停在最后一档（不得无限增长）")
        XCTAssertEqual(SyncEngine.backoffDelay(forAttempt: -1, using: ladder), .seconds(30),
                       "负下标必须钳到第 0 档（不得崩）")
        XCTAssertEqual(SyncEngine.backoffDelay(forAttempt: 3, using: []), .seconds(30),
                       "空阶梯必须给安全默认值")
        // 生产阶梯就是 #140 建议的三档
        XCTAssertEqual(SyncEngine.retryBackoff, ladder, "生产退避阶梯必须是 30s / 2m / 10m")
    }

    // MARK: - 辅助

    /// 线程安全的调用计数：`errorMatcher` 在 URLProtocol 线程被调，测试在主线程读，
    /// 直接用裸 `var` 计数是数据竞争（Swift 5 minimal 不报但行为不可靠）。
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        /// 返回本次是第几次调用（从 1 开始）
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    @MainActor
    private func makeEngine(modelContext: ModelContext? = nil) -> SyncEngine {
        let client = SyncCloudClient(session: RetryStubURLProtocol.makeSession())
        return SyncEngine(client: client, store: store, modelContext: modelContext)
    }

    /// 造「已登录」前置。`accessExpiresInMs` 为负即表示令牌已过期。
    private func login(accessExpiresInMs: Int64) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        store.saveCredentials(SyncLocalStore.Credentials(
            accessToken: "atk-old", refreshToken: "rtk-old", userId: "u1", email: "b52@test.mail",
            deviceId: "d1",
            accessExpireAtMs: now + accessExpiresInMs,
            refreshExpireAtMs: now + 30 * 24 * 3600 * 1000))
    }

    private func enqueueFavorite(albumId: Int64, title: String = "待传书") {
        store.enqueueFavoriteUpsert(src: SourceRegistry.TINGYOU, albumId: albumId,
                                    title: title, author: nil, coverUrl: nil, detailPath: nil)
    }

    /// 让引擎内部的 Task（去抖 / 退避）有机会跑完，并确保本轮 syncing 已退出。
    @MainActor
    private func drain(_ engine: SyncEngine) async {
        for _ in 0..<40 {
            if !engine.syncing { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func path(_ req: URLRequest) -> String {
        guard let url = req.url else { return "" }
        // 去掉前导 "/"，得到 "auth/v1/refresh" 这类端点路径
        return url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
    }

    // MARK: - 云端响应构造（契约信封 { code, message, data }）

    private static func ok(_ dataJSON: String) -> (Int, Data) {
        (200, Data(#"{"code":0,"message":"ok","data":\#(dataJSON)}"#.utf8))
    }

    private static func err(_ code: Int, _ message: String) -> (Int, Data) {
        (200, Data(#"{"code":\#(code),"message":"\#(message)","data":null}"#.utf8))
    }

    private static func refreshJSON(token: String) -> String {
        #"{"access_token":"\#(token)","access_expire_in":3600,"refresh_token":"rtk-new","refresh_expire_in":2592000}"#
    }

    /// push 响应必须回**真实 client_op_id**：results 为空会被引擎判成
    /// 「未返回可识别 id → 整体留队」，那是另一条分支，不能用来模拟成功。
    private static func pushJSON(results: [(String, String)]) -> String {
        let items = results
            .map { #"{"client_op_id":"\#($0.0)","status":"\#($0.1)"}"# }
            .joined(separator: ",")
        return #"{"server_seq":10,"results":[\#(items)],"processed":\#(results.count),"submitted":\#(results.count)}"#
    }

    private static func pullJSON(serverSeq: Int64, favorites: [[String: Any]],
                                 progress: [[String: Any]]) -> String {
        #"{"server_seq":\#(serverSeq),"since_seq":0,"snapshot_required":false,"favorites":\#(jsonArray(favorites)),"progress":\#(jsonArray(progress))}"#
    }

    private static func jsonArray(_ rows: [[String: Any]]) -> String {
        guard !rows.isEmpty else { return "[]" }
        let parts = rows.map { row -> String in
            let body = row.keys.sorted().map { key -> String in
                let v = row[key]!
                if let s = v as? String { return #""\#(key)":"\#(s)""# }
                return #""\#(key)":\#(v)"#
            }.joined(separator: ",")
            return "{\(body)}"
        }
        return "[\(parts.joined(separator: ","))]"
    }
}
