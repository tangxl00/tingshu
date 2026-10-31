import XCTest
import SwiftData
@testable import TingYou

/// build 53 · 复检 NO-GO 放行条件的验收用例（A1 / A2 / P1-3）。
///
/// - A1 退避链生命周期：b52 的 AccountSyncScreen `.onDisappear` 无条件
///   `stopRetry()`——用户「看一眼、退回上一级」就清掉退避链，红字恒挂。
///   修复 = 退避链只在 App 进后台时停（`handleEnterBackground` 是唯一停点），
///   回前台（`handleBecomeActive`）与重新进页（`onSyncPageEnter`）恢复。
/// - A2 重试档位计法：b52 `stopRetry()` 不重置 `retryAttempt`，反复进出页
///   档位跨轮继承、4 次往返即饱和 10 分钟档。修复 = 按「本轮连续失败」计档
///   （进页归零 / 本轮失败 +1 / 成功归零）。
/// - P1-3 失败维度拆分：`renewalState` 不再兼作同步失败通道，同步失败走
///   独立 `syncFailure`，UI 两个维度各自如实呈现。
///
/// 全部行为级：真实 SyncEngine + RetryStubURLProtocol 注入云端响应 /
/// 传输层错误，断言可观察结果（retryTask 存活、retryAttempt、outbox、
/// 两维状态）。唯一例外 testAccountSyncScreenWiring 是接线守卫（UI 生命
/// 周期在单测沙箱无法真跑），如实标注。
final class Build53FeatureTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SyncLocalStore!

    override func setUp() async throws {
        try await super.setUp()
        RetryStubURLProtocol.reset()
        suiteName = "b53-sync-\(UUID().uuidString)"
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

    // MARK: - A1 · 退避链生命周期

    /// A1 核心：App 进后台是**唯一**停链点，且只停定时器不停「失败意图」；
    /// 回前台无需任何用户动作即续挂。b52 的缺陷形态（退页即清链）在本
    /// 断言下不可复现——退页在引擎侧没有任何停链调用。
    @MainActor
    func testBackgroundIsTheOnlyRetryStopPointAndForegroundResumes() async throws {
        login(accessExpiresInMs: 10 * 60_000)
        enqueueFavorite(albumId: 7301)
        installSyncTransportFailure()          // push 一律传输层超时（同步维度瞬态）
        let engine = makeEngine()
        engine.retryBackoffOverride = [.seconds(600)]   // 只观察状态，不让重试真跑

        await engine.syncNow()
        XCTAssertTrue(engine.syncFailure.isRetrying, "前置：瞬态失败必须挂上自动重试")
        XCTAssertNotNil(engine.retryTaskForTesting, "前置：退避任务在途")

        // 模拟 App 进后台：定时器停，意图保留
        engine.handleEnterBackground()
        XCTAssertNil(engine.retryTaskForTesting, "进后台必须停掉在途退避定时器（不空转）")
        XCTAssertTrue(engine.syncFailure.isRetrying,
                      "进后台只停定时器，失败意图必须保留（否则回前台无从恢复）")
        XCTAssertEqual(engine.phase, .loggedIn, "进后台不得登出")
        XCTAssertEqual(store.outboxCount, 1, "待补传不得因进后台丢失")

        // 模拟回到前台：无需任何用户动作，链自动续挂
        engine.handleBecomeActive()
        XCTAssertNotNil(engine.retryTaskForTesting,
                        "回前台必须自动续挂退避（b52 缺陷：链已被清，回前台什么都不发生）")
        XCTAssertTrue(engine.syncFailure.isRetrying, "回前台后意图仍在")
        engine.stopRetry()
    }

    /// A1 验收（出页/回页自愈）：瞬态失败 → 用户离开同步页（什么都不发生）
    /// → 退避自愈路径照常完成 → 回页看到的是已恢复状态。全程无任何点击。
    @MainActor
    func testPageExitDoesNotBlockHealWithoutAnyTap() async throws {
        login(accessExpiresInMs: 10 * 60_000)
        enqueueFavorite(albumId: 7302)
        let opId = store.loadOutbox()[0].clientOpId
        let pushAttempts = AttemptCounter()
        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/push":
                // 前 2 次传输层超时，之后成功
                return Self.ok(Self.pushJSON(results: [(opId, "success")]))
            case "sync/v1/pull":
                return Self.ok(Self.pullJSON(serverSeq: 31, favorites: [], progress: []))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        RetryStubURLProtocol.errorMatcher = { req in
            guard Self.path(req) == "sync/v1/push" else { return nil }
            if pushAttempts.next() <= 2 { return URLError(.timedOut) }
            return nil
        }
        let engine = makeEngine()
        engine.retryBackoffOverride = [.milliseconds(80), .milliseconds(120)]

        await engine.syncNow()
        XCTAssertTrue(engine.syncFailure.isRetrying, "前置：瞬态失败挂重试")
        XCTAssertEqual(store.outboxCount, 1)

        // 「用户退出同步页」：修复后引擎侧无任何停链副作用（b52 此处链已被
        // onDisappear stopRetry 清掉）。退避只由引擎自己驱动：
        var waited = 0
        while store.outboxCount > 0 && waited < 100 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        XCTAssertEqual(store.outboxCount, 0, "离开页面不得阻断自愈（无任何点击）")
        XCTAssertEqual(engine.syncFailure, .none, "自愈后同步维度不得残留告警")
        XCTAssertEqual(engine.renewalState, .idle, "自愈后续期维度不得残留告警")
        XCTAssertGreaterThan(engine.lastSyncAtMs, 0)

        // 回页（重新进同步页）：看到的是干净状态，且不产生新失败
        RetryStubURLProtocol.errorMatcher = nil
        await engine.onSyncPageEnter()
        await drain(engine)
        XCTAssertEqual(engine.syncFailure, .none, "回页后不得有失败残留")
        XCTAssertEqual(engine.retryAttempt, 0, "成功后档位必须归零")
    }

    /// A1 验收（链已被后台停掉后，重新进页是恢复入口）：
    /// 失败 → 进后台（链停）→ 重新进同步页 → 必须重新挂上/完成恢复。
    @MainActor
    func testReenterPageResumesChainStoppedByBackground() async throws {
        login(accessExpiresInMs: 10 * 60_000)
        enqueueFavorite(albumId: 7303)
        let opId = store.loadOutbox()[0].clientOpId
        var failFirst = true
        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/push":
                return Self.ok(Self.pushJSON(results: [(opId, "success")]))
            case "sync/v1/pull":
                return Self.ok(Self.pullJSON(serverSeq: 32, favorites: [], progress: []))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        RetryStubURLProtocol.errorMatcher = { req in
            guard Self.path(req) == "sync/v1/push" else { return nil }
            return failFirst ? URLError(.timedOut) : nil
        }
        let engine = makeEngine()
        engine.retryBackoffOverride = [.seconds(600)]

        await engine.syncNow()
        XCTAssertTrue(engine.syncFailure.isRetrying, "前置：失败挂重试")
        engine.handleEnterBackground()
        XCTAssertNil(engine.retryTaskForTesting, "前置：链已被后台停掉")

        // 重新进页（界面 .task 等价入口），服务端已恢复
        failFirst = false
        await engine.onSyncPageEnter()
        await drain(engine)
        XCTAssertEqual(store.outboxCount, 0, "重新进页必须完成恢复（清空待补传）")
        XCTAssertEqual(engine.syncFailure, .none, "恢复后不得残留同步失败告警")
        XCTAssertGreaterThan(engine.lastSyncAtMs, 0)
        XCTAssertEqual(engine.retryAttempt, 0)
    }

    /// A1 接线守卫（如实标注：非行为级——UI 生命周期在单测沙箱无法真跑）：
    /// AccountSyncScreen 不得再有 `.onDisappear` 停链；进页入口与两维
    /// 告警行必须接线。
    func testAccountSyncScreenWiring() throws {
        let screen = Self.codeOnly(try Self.source("TingYou/UI/Mine/AccountSyncScreen.swift"))
        XCTAssertFalse(screen.contains("onDisappear"),
                      "同步页不得再挂 onDisappear 停链（b52 缺陷：退页即清退避链）——停链唯一时机是进后台")
        XCTAssertTrue(screen.contains(".task"),
                      "进页自动同步入口（.task）必须保留")
        XCTAssertTrue(screen.contains("await engine.onSyncPageEnter()"),
                      "进页必须走 onSyncPageEnter（A1 恢复入口 + A2 档位归零点）")
        XCTAssertTrue(screen.contains("syncFailureRow(engine)"),
                      "同步维度失败必须有独立的界面行（P1-3：两维各自呈现）")
        XCTAssertTrue(screen.contains("renewalRow(engine)"),
                      "续期维度告警行必须保留")
    }

    // MARK: - A2 · 重试档位按「本轮连续失败」计

    /// A2 验收：反复进出页面不得让档位跨轮继承。每轮（onSyncPageEnter）
    /// 失败后 retryAttempt 必须是 1（下一跳仍是 30s 档），而不是 1→2→3→4
    /// （b52 缺陷：4 次往返即饱和 10 分钟档）。同一轮内连续失败仍正常爬档，
    /// 成功后归零——证明「归零」是按轮重置而不是计数坏了。
    @MainActor
    func testRetryTierResetsEachPageVisitNotAcrossVisits() async throws {
        login(accessExpiresInMs: 10 * 60_000)
        enqueueFavorite(albumId: 7304)
        installSyncTransportFailure()
        let engine = makeEngine()
        engine.retryBackoffOverride = [.seconds(600)]   // 观察计数，不让重试真跑

        // 4 轮「进页 → 失败」：每轮档位都从零开始
        for visit in 1...4 {
            await engine.onSyncPageEnter()
            XCTAssertEqual(engine.retryAttempt, 1,
                           "第 \(visit) 次进页后失败，档位必须是第 1 档（下一跳 30s）——" +
                           "不得跨轮继承（b52 缺陷：第 4 次往返已饱和 10 分钟档）")
            // 本轮刚挂的这一跳用的就是第 0 档间隔
            XCTAssertEqual(SyncEngine.backoffDelay(forAttempt: engine.retryAttempt - 1,
                                                   using: SyncEngine.retryBackoff),
                           .seconds(30),
                           "每轮首跳必须仍在 30s 档")
        }

        // 同一轮内（不重新进页）连续失败：档位正常爬升——重置是按轮的，计数没坏
        await engine.syncNow()
        XCTAssertEqual(engine.retryAttempt, 2, "同一轮内第二次失败，档位必须爬到 2（下一次失败将用第 2 档）")
        XCTAssertEqual(SyncEngine.backoffDelay(forAttempt: engine.retryAttempt - 1,
                                               using: SyncEngine.retryBackoff),
                       .seconds(120), "同一轮内第二次失败，刚挂的这一跳必须是 120s 档")

        // 成功后归零
        RetryStubURLProtocol.errorMatcher = nil
        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/push":
                let ops = self.store.loadOutbox()
                let results = ops.map { ($0.clientOpId, "success") }
                return Self.ok(Self.pushJSON(results: results))
            case "sync/v1/pull":
                return Self.ok(Self.pullJSON(serverSeq: 33, favorites: [], progress: []))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        await engine.syncNow()
        XCTAssertEqual(engine.retryAttempt, 0, "成功后档位必须归零")
        XCTAssertEqual(engine.syncFailure, .none)
        XCTAssertEqual(store.outboxCount, 0)
    }

    // MARK: - P1-3 · 失败维度拆分

    /// P1-3：续期维度的瞬态失败只标续期维度——`syncFailure` 必须保持 .none
    ///（b52 误用 renewalState 作通用失败通道，两维互相污染）。
    @MainActor
    func testRenewalFailureOnlyMarksRenewalDimension() async throws {
        login(accessExpiresInMs: 10 * 60_000)
        enqueueFavorite(albumId: 7305)
        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/push":
                return Self.err(40003, "access token expired")   // 触发续期
            case "auth/v1/refresh":
                return Self.ok(Self.refreshJSON(token: "unused"))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        // 续期请求传输层瞬态失败（真实 URLError，非被重包的 40003）
        RetryStubURLProtocol.errorMatcher = { req in
            guard Self.path(req) == "auth/v1/refresh" else { return nil }
            return URLError(.timedOut)
        }
        let engine = makeEngine()
        engine.retryBackoffOverride = [.seconds(600)]
        await engine.syncNow()

        XCTAssertTrue(engine.renewalState.isRetrying,
                      "续期瞬态失败必须标在续期维度")
        XCTAssertEqual(engine.syncFailure, .none,
                       "续期失败不得写进同步维度（P1-3：两维各自呈现）")
        XCTAssertEqual(engine.phase, .loggedIn, "瞬态失败保留登录态")
        XCTAssertEqual(store.outboxCount, 1, "待补传必须留队")
        engine.stopRetry()
    }

    /// P1-3：同步维度的瞬态失败（令牌有效、纯传输层错误）只标同步维度——
    /// `renewalState` 必须保持 .idle（b52 会把它也写成 retryScheduled，
    /// 界面误报「自动续期重试中」）。
    @MainActor
    func testSyncFailureOnlyMarksSyncDimension() async throws {
        login(accessExpiresInMs: 10 * 60_000)
        enqueueFavorite(albumId: 7306)
        installSyncTransportFailure()
        let engine = makeEngine()
        engine.retryBackoffOverride = [.seconds(600)]
        await engine.syncNow()

        XCTAssertTrue(engine.syncFailure.isRetrying,
                      "同步瞬态失败必须标在同步维度")
        XCTAssertEqual(engine.renewalState, .idle,
                       "令牌有效且未触发续期，续期维度必须保持 idle（不得误报续期重试中）")
        XCTAssertEqual(engine.phase, .loggedIn)
        XCTAssertEqual(store.outboxCount, 1, "待补传必须留队")
        engine.stopRetry()
    }

    // MARK: - 工具

    /// push 一律传输层超时（同步维度瞬态失败的最小注入）。
    /// matcher 在请求发出前由 setUp 后调用方装好，命中**本次及后续所有** push。
    private func installSyncTransportFailure() {
        RetryStubURLProtocol.handler = { req in
            switch Self.path(req) {
            case "sync/v1/pull":
                return Self.ok(Self.pullJSON(serverSeq: 30, favorites: [], progress: []))
            default:
                return Self.err(50001, "unexpected \(Self.path(req))")
            }
        }
        RetryStubURLProtocol.errorMatcher = { req in
            guard Self.path(req) == "sync/v1/push" else { return nil }
            return URLError(.timedOut)
        }
    }

    /// 线程安全的调用计数（errorMatcher 在 URLProtocol 线程被调）。
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
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

    private func login(accessExpiresInMs: Int64) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        store.saveCredentials(SyncLocalStore.Credentials(
            accessToken: "atk-old", refreshToken: "rtk-old", userId: "u1", email: "b53@test.mail",
            deviceId: "d1",
            accessExpireAtMs: now + accessExpiresInMs,
            refreshExpireAtMs: now + 30 * 24 * 3600 * 1000))
    }

    private func enqueueFavorite(albumId: Int64, title: String = "待传书") {
        store.enqueueFavoriteUpsert(src: SourceRegistry.TINGYOU, albumId: albumId,
                                    title: title, author: nil, coverUrl: nil, detailPath: nil)
    }

    @MainActor
    private func drain(_ engine: SyncEngine) async {
        for _ in 0..<40 {
            if !engine.syncing { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func path(_ req: URLRequest) -> String {
        guard let url = req.url else { return "" }
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

    // MARK: - 源码读取（崩溃安全：XCTFail + throw，不 fatalError）

    private static func source(_ rel: String) throws -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("\(rel) 不存在：\(path)——路径布局变化时请同步修正本测试")
            throw NSError(domain: "Build53FeatureTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing source \(rel)"])
        }
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(rel) 不可读：\(path)")
            throw NSError(domain: "Build53FeatureTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "unreadable source \(rel)"])
        }
        return src
    }

    /// 剔除整行注释（trim 后以 // 开头）。
    private static func codeOnly(_ src: String) -> String {
        src.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }
}
