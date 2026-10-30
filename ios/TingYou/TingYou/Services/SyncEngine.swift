import Foundation
import SwiftData
import UIKit

/// build 50 · 云同步引擎（对齐 PC 端 v1.1.13 交互）：
/// - 邮箱 + 验证码登录（/auth/v1/code → /auth/v1/login）
/// - 收藏 / 播放进度双向同步（push outbox → pull → LWW 合并到 SwiftData）
/// - 断网本地排队（outbox 持久化），联网 / 回前台自动补传
/// - 40003 自动 refresh 后重试一次；40002 清凭据回未登录态
/// - 免费版云函数单次 3 秒：首次登录云端建 9 张表可能超时 → 友好重试提示
@MainActor
@Observable
final class SyncEngine {
    enum Phase: Equatable {
        case loggedOut
        case loggedIn
    }

    /// build 52 · 续期状态（#140 放行条件 1）。
    /// 原实现把 withAuth 里被吞掉的任意非 40002 异常重包成 40003，而 40003 的
    /// 展示文案是「登录状态已过期，正在自动续期」——终局失败被伪装成进行中，
    /// 真机实测红字挂 3.5 小时不动、待补传数永不归零。
    /// 现拆成四个可区分状态：进行中 / 瞬态失败（可自动恢复）/ 终局失败（需重新登录）。
    enum RenewalState: Equatable {
        /// 无续期动作、无异常
        case idle
        /// 正在续期（瞬态：当前这次请求在等 refresh 结果）
        case refreshing
        /// 续期失败但可自动恢复（网络 / 超时 / 服务端异常）——稍后自动重试
        case retryScheduled(String)
        /// 续期失败且不可自动恢复（refresh_token 失效 / 续期后仍被拒）——必须重新登录
        case terminal(String)

        /// build 52 · 条件 1：终局态（点「立即同步」也不会自愈，必须重新登录）
        var isTerminal: Bool {
            if case .terminal = self { return true }
            return false
        }
        /// build 52 · 条件 1：瞬态失败（可自动恢复，会按退避阶梯重试）
        var isRetrying: Bool {
            if case .retryScheduled = self { return true }
            return false
        }
    }

    private(set) var phase: Phase = .loggedOut
    private(set) var email: String?
    private(set) var syncing = false
    private(set) var lastSyncAtMs: Int64 = 0
    private(set) var pendingOps = 0
    private(set) var lastMessage: String?
    /// build 52 · 条件 1：同步页据此区分「瞬态续期中」与「续期失败，请重新登录」
    private(set) var renewalState: RenewalState = .idle
    /// build 51 · P1-2：本轮 push 中被服务端判为 failed（非 success/duplicate）的 op 数
    private(set) var lastPushFailedCount = 0
    /// build 51 · P1-3：本轮 push 未能确认处理（缺 client_op_id / 未回 results）的 op 数
    private(set) var lastPushUnhandledCount = 0
    /// build 52 · 条件 2：当前已失败几次（退避阶梯下标），成功后归零
    private(set) var retryAttempt = 0

    private let client: SyncCloudClient
    private let store: SyncLocalStore
    private let modelContext: ModelContext?
    private var flushTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    /// build 52 · 条件 3 测试接缝：merge 的落库动作（生产路径走 `try ctx.save()`）。
    /// 行为级用例注入抛错闭包，验证「save 抛错 → lastSeq 不推进 + 有明确文案」。
    var mergeCommit: ((ModelContext) throws -> Void)?
    /// build 52 · 条件 2 测试接缝：退避阶梯可注入（用例用毫秒级阶梯跑自动重试闭环）
    var retryBackoffOverride: [Duration]?
    /// build 52 · 条件 2 测试接缝：是否有挂起的自动重试（用例断言「终局态不得再挂重试」）
    var retryTaskForTesting: Task<Void, Never>? { retryTask }
    /// deinit 是 nonisolated 上下文，@MainActor 隔离的存储属性不能直接读；
    /// 观察者 token 只在主线程写入/读取，nonisolated(unsafe) 标注该事实。
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    /// push 客户端分片（契约 push_client_chunk=100；服务端硬上限 500）
    static let pushChunk = 100
    /// pull 增量分页循环上限（每页 100 条变更，防异常死循环）
    static let pullMaxRounds = 10

    /// build 52 · 条件 2：失败退避阶梯（30s → 2m → 10m，之后停在上限）。
    /// 原实现续期失败后无任何重试入口：`accessExpireAtMs` 全仓零读取点、
    /// 同步页也不触发 syncNow，真机实测待补传 1 条恒挂 3.5h 不自愈。
    static let retryBackoff: [Duration] = [.seconds(30), .seconds(120), .seconds(600)]
    /// build 52 · 条件 2：访问令牌到期前多久主动续期（把 accessExpireAtMs 变成真实读取点）
    static let proactiveRenewWindowMs: Int64 = 5 * 60 * 1000

    /// build 52 · 条件 1：三种续期/同步状态的**唯一文案事实源**（界面与用例共用，
    /// 避免「界面上写一套、用例里扫另一套字符串」）。语义硬约束：
    /// - `refreshingHeadline` 只描述**真的在进行中**的动作；
    /// - `retryHeadline` 描述可自动恢复的失败（不是成功态）；
    /// - `terminalHeadline` 必须明确「重新登录」——用户看到才知道点「立即同步」无用。
    static let refreshingHeadline = "正在自动续期…"
    static let retryHeadline = "同步未完成，稍后自动重试"
    static let terminalHeadline = "续期失败，请重新登录"

    init(client: SyncCloudClient = SyncCloudClient(),
         store: SyncLocalStore = .shared,
         modelContext: ModelContext? = nil) {
        self.client = client
        self.store = store
        self.modelContext = modelContext
        if let cred = store.loadCredentials() {
            phase = .loggedIn
            email = cred.email
        }
        lastSyncAtMs = store.lastSyncAtMs
        pendingOps = store.outboxCount
        installObservers()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - 自动补传触发（outbox 变化去抖 + 回前台节流）

    private func installObservers() {
        let outboxObs = NotificationCenter.default.addObserver(
            forName: SyncLocalStore.outboxChangedNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingOps = self.store.outboxCount
                self.scheduleAutoFlush()
            }
        }
        let activeObs = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshOnForeground()
            }
        }
        observers = [outboxObs, activeObs]
    }

    /// outbox 变化后 3 秒去抖补传（进度 5s 节流入队不打爆云端）
    private func scheduleAutoFlush() {
        guard phase == .loggedIn, !syncing else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            await self.syncNow()
        }
    }

    /// 回前台：超过 5 分钟未同步或有积压 → 全量同步一次
    private func refreshOnForeground() {
        guard phase == .loggedIn, !syncing else { return }
        let stale = Date().timeIntervalSince1970 * 1000 - Double(lastSyncAtMs) > 5 * 60 * 1000
        guard stale || store.outboxCount > 0 || needsProactiveRenewal() else { return }
        Task { await onSyncPageEnter() }
    }

    // MARK: - build 52 · 条件 2：进页自动同步 + 主动续期（accessExpireAtMs 的真实读取点）

    /// 访问令牌是否已进入「提前续期窗口」（到期前 5 分钟）。这是 `accessExpireAtMs`
    /// 的首个读取点——原实现全仓零读取，令牌过期后只能等服务端回 40003 才发现。
    func needsProactiveRenewal(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        guard let cred = store.loadCredentials(), cred.accessExpireAtMs > 0 else { return false }
        return cred.accessExpireAtMs - nowMs <= Self.proactiveRenewWindowMs
    }

    /// 进入同步页 / 回前台时的统一入口：先按 accessExpireAtMs 提前续期，
    /// 再触发一次同步。原实现同步页既无 syncNow 调用也无任何定时器，
    /// 叠加「续期失败无重试」→ 真机待补传 1 条恒挂 3.5h（#140 实测）。
    func onSyncPageEnter() async {
        guard phase == .loggedIn, store.isLoggedIn, !syncing else { return }
        if needsProactiveRenewal(), await renewAccessTokenInAdvance() == false {
            return   // 提前续期失败：renewAccessTokenInAdvance 内已挂退避重试
        }
        await syncNow()
    }

    /// 提前续期（不经服务端 40003 触发）。成功返回 true 并落盘新令牌；
    /// 失败按可恢复性分派：40002 → 终局（清凭据回未登录）；其余 → 瞬态 + 退避重试。
    func renewAccessTokenInAdvance() async -> Bool {
        guard var cred = store.loadCredentials() else { return false }
        renewalState = .refreshing
        do {
            let refreshed = try await client.refresh(refreshToken: cred.refreshToken)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            cred.accessToken = refreshed.accessToken
            cred.refreshToken = refreshed.refreshToken
            cred.accessExpireAtMs = now + Int64(refreshed.accessExpireIn) * 1000
            cred.refreshExpireAtMs = now + Int64(refreshed.refreshExpireIn) * 1000
            store.saveCredentials(cred)
            renewalState = .idle
            return true
        } catch let e as SyncCloudError where e.code == 40002 {
            demoteToLoggedOut("登录状态已失效，请重新登录")
            _ = e
            return false
        } catch {
            // 瞬态：凭据保留，交给退避重试（文案必须写「未成功」而不是「正在续期」）
            let text = "自动续期未成功：\(friendlyMessage(error))"
            lastMessage = text
            renewalState = .retryScheduled(text)
            scheduleRetry()
            return false
        }
    }

    /// 退避间隔（纯函数）：30s → 2m → 10m，超出阶梯后钳到最后一档。
    static func backoffDelay(forAttempt attempt: Int, using ladder: [Duration]) -> Duration {
        guard !ladder.isEmpty else { return .seconds(30) }
        let idx = min(max(attempt, 0), ladder.count - 1)
        return ladder[idx]
    }

    /// 失败后按阶梯挂下一次自动重试（同一时刻只挂一个；syncNow 开始时清掉旧的）。
    func scheduleRetry() {
        guard phase == .loggedIn else { return }
        guard retryTask == nil else { return }
        let ladder = retryBackoffOverride ?? Self.retryBackoff
        let delay = Self.backoffDelay(forAttempt: retryAttempt, using: ladder)
        retryAttempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.retryTask = nil }
            await self.syncNow()
        }
    }

    /// 页面离开 / 登出时停掉在途重试（避免后台空转）
    func stopRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    /// 终局失败：清凭据回未登录态（不会再有任何自动恢复动作）
    private func demoteToLoggedOut(_ text: String) {
        store.resetForLogout()
        phase = .loggedOut
        email = nil
        lastMessage = text
        renewalState = .terminal(text)
        stopRetry()
    }

    // MARK: - 登录 / 登出

    func requestCode(email: String) async throws -> Int {
        let data = try await client.requestCode(email: email)
        return data.resendIn ?? 60
    }

    func login(email: String, code: String) async throws {
        let deviceId = store.deviceId()
        let data = try await client.login(email: email, code: code, deviceId: deviceId)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        store.saveCredentials(SyncLocalStore.Credentials(
            accessToken: data.accessToken,
            refreshToken: data.refreshToken,
            userId: data.user.userId,
            email: data.user.email,
            deviceId: data.deviceId,
            accessExpireAtMs: now + Int64(data.accessExpireIn) * 1000,
            refreshExpireAtMs: now + Int64(data.refreshExpireIn) * 1000))
        phase = .loggedIn
        self.email = data.user.email
        lastMessage = nil
        await syncNow()
    }

    func logout() async {
        if let cred = store.loadCredentials() {
            // 尽力通知服务端注销本设备（失败不阻断本地登出）
            try? await client.logout(accessToken: cred.accessToken)
        }
        store.resetForLogout()
        phase = .loggedOut
        email = nil
        pendingOps = 0
        lastSyncAtMs = 0
        lastMessage = nil
        renewalState = .idle
        retryAttempt = 0
        stopRetry()
    }

    // MARK: - 全量同步（push → pull → 快照回传的本地独有数据再 push）

    func syncNow() async {
        guard !syncing else { return }
        guard phase == .loggedIn, store.isLoggedIn else { return }
        syncing = true
        // build 52 · 条件 2：本次同步会覆盖重试意图，先摘掉挂着的旧定时器
        stopRetry()
        // build 52 · 条件 3：每轮开始先归零 push 计数，避免上一轮的残留值
        // 让本轮（队列已空、根本没 push）也判成「部分失败」而不刷新同步时间。
        lastPushFailedCount = 0
        lastPushUnhandledCount = 0
        defer { syncing = false; pendingOps = store.outboxCount }
        do {
            try await pushOutbox()
            let merged = try await pullAndMerge()
            // build 51 · P1-3：落库失败时 merge 已写入 lastMessage，
            // 这里不能再把 lastMessage 清成 nil、也不能记账「同步成功」
            if !merged {
                // 落库失败属可恢复（下次重试会再拉同一批），同样要挂退避重试
                renewalState = .retryScheduled(lastMessage ?? "本地数据写入失败")
                scheduleRetry()
                return
            }
            // build 52 · 条件 3：首轮 push 已有失败/未确认时，不再在同一轮里
            // 二次推送同一批（否则一轮打两次、退避形同虚设）。
            if store.outboxCount > 0, lastPushFailedCount == 0, lastPushUnhandledCount == 0 {
                try await pushOutbox()
            }
            // build 52 · 条件 3（#140）：push 部分失败时不得刷新「上次同步成功」。
            // 原实现无条件写 store.lastSyncAtMs —— 服务端判 failed 的 op 还在队列里，
            // 界面却显示「上次同步成功」，用户无从判断补传是否真的完成。
            if lastPushFailedCount > 0 || lastPushUnhandledCount > 0 {
                let left = max(lastPushFailedCount, lastPushUnhandledCount)
                let text = "有 \(left) 条变更云端未确认，已保留在队列中，稍后自动重试"
                lastMessage = text
                renewalState = .retryScheduled(text)
                scheduleRetry()
                return
            }
            store.lastSyncAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            lastSyncAtMs = store.lastSyncAtMs
            lastMessage = nil
            renewalState = .idle
            retryAttempt = 0
        } catch {
            let text = friendlyMessage(error)
            lastMessage = text
            // 终局（已回未登录态）由 withAuth 内分派，此处不重复处理。
            // build 52 · 条件 1：withAuth 已在续期分支写入语义明确的
            // 「自动续期未成功：<真实原因>」——这里**不得再覆盖**成通用文案，
            // 否则界面又变回看不出「是续期失败还是普通同步失败」的同一句话。
            if phase == .loggedIn {
                if !renewalState.isRetrying {
                    renewalState = .retryScheduled(text)
                }
                scheduleRetry()
            }
        }
    }

    // MARK: - 鉴权包装（40003 refresh 重试一次；40002 清凭据）

    /// build 52 · 条件 1（#140 P1）：续期失败**不再重包 40003**。
    ///
    /// 原实现 catch 里把「被 withAuth 吞掉的任意非 40002 异常」重包成
    /// `SyncCloudError(40003)`，而 40003 的展示文案是「登录状态已过期，正在自动
    /// 续期」——于是一次终局失败被渲染成「进行中」，真机红字挂 3.5h 不动。
    ///
    /// 现在分三种去向，语义互不混淆：
    /// 1. refresh 回 40002（rtk 失效）→ 终局：清凭据回未登录，`renewalState=.terminal`
    /// 2. refresh 后重试仍回 40003 → 终局：令牌续了还被拒，抛 40004（新内部码）
    /// 3. 网络 / 超时 / 5xx 等 → 瞬态：原样抛出真实错误（**不再伪装成 40003**），
    ///    由 syncNow 记 `.retryScheduled` 并挂退避重试，凭据保留。
    private func withAuth<T>(_ work: (_ accessToken: String) async throws -> T) async throws -> T {
        guard var cred = store.loadCredentials() else {
            throw SyncCloudError(code: 40002, message: "未登录")
        }
        // ---- 第一次尝试：只有 40003（访问令牌过期）才进入续期分支 ----
        do {
            return try await work(cred.accessToken)
        } catch let e as SyncCloudError where e.code == 40002 {
            demoteToLoggedOut("登录状态已失效，请重新登录")
            throw e
        } catch let e as SyncCloudError where e.code == 40003 {
            _ = e   // 落到下面的续期分支
        }

        // ---- 续期（瞬态窗口：此刻界面上才允许出现「正在续期」）----
        renewalState = .refreshing
        let refreshed: SyncRefreshData
        do {
            refreshed = try await client.refresh(refreshToken: cred.refreshToken)
        } catch let e2 as SyncCloudError where e2.code == 40002 {
            // 终局 1：refresh_token 失效 / 已被轮换作废 → 必须重新登录
            demoteToLoggedOut("登录状态已失效，请重新登录")
            throw e2
        } catch {
            // 瞬态：网络 / 超时 / 5xx。**原样抛出真实错误，不重包 40003**（#140 根因）
            renewalState = .retryScheduled("自动续期未成功：\(friendlyMessage(error))")
            throw error
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        cred.accessToken = refreshed.accessToken
        cred.refreshToken = refreshed.refreshToken
        cred.accessExpireAtMs = now + Int64(refreshed.accessExpireIn) * 1000
        cred.refreshExpireAtMs = now + Int64(refreshed.refreshExpireIn) * 1000
        store.saveCredentials(cred)
        renewalState = .idle

        // ---- 续期后重试一次 ----
        do {
            return try await work(cred.accessToken)
        } catch let e3 as SyncCloudError where e3.code == 40002 {
            demoteToLoggedOut("登录状态已失效，请重新登录")
            throw e3
        } catch let e3 as SyncCloudError where e3.code == 40003 {
            // 终局 2：令牌续了仍被拒（服务端侧账号状态异常）→ 内部码 40004
            let text = "登录状态异常：续期后仍被拒绝，请重新登录"
            demoteToLoggedOut(text)
            throw SyncCloudError(code: SyncCloudError.renewalRejectedCode, message: text)
        }
    }

    // MARK: - push（outbox 分片冲刷）

    private func pushOutbox() async throws {
        for _ in 0..<Self.pullMaxRounds {
            let chunk = store.takeOutboxChunk(max: Self.pushChunk)
            guard !chunk.isEmpty else { return }
            let data = try await withAuth { atk in
                try await client.push(accessToken: atk, ops: chunk)
            }
            // build 51 · P1-2（质检必修）：必须消费 results[].status——
            // 原实现只取 clientOpId 当「已处理」，服务端返回 status=failed 的 op
            // 也被移出 outbox，变更静默丢失（无重推、无提示）。
            // 现只移除 success / duplicate（duplicate = 7 天幂等重放，等价成功）；
            // failed / 未知 status 一律留队，并计数告警。
            let items = data.results ?? []
            var handled: [String] = []
            var failed = 0
            for item in items {
                guard let id = item.clientOpId, !id.isEmpty else { continue }
                switch (item.status ?? "").lowercased() {
                case "success", "duplicate", "ok":
                    handled.append(id)
                default:
                    failed += 1
                }
            }
            lastPushFailedCount = failed
            if failed > 0 {
                print("⚠️ sync push: \(failed)/\(items.count) 条 op 服务端 status 非成功，保留在 outbox 等待重推")
            }
            guard !handled.isEmpty else {
                // build 51 · P1-3：原来这里直接 return——服务端一条 id 都没回时
                // （缺 id / results 为空）队列永远滞留，且外层看不出来。
                // 现记录未处理条数并跳出本轮（保留队列，等下次 syncNow 重推）。
                lastPushUnhandledCount = chunk.count
                if failed == 0 {
                    print("⚠️ sync push: 本轮 \(chunk.count) 条 op 未返回可识别 client_op_id，整体留队重推")
                }
                return
            }
            lastPushUnhandledCount = chunk.count - handled.count
            store.removeOutbox(opIds: handled)
            if let seq = data.serverSeq, seq > store.lastSeq {
                store.lastSeq = seq
            }
            if store.outboxCount == 0 { return }
            // 有 op 被判 failed：本轮到此为止（留下次 syncNow 重推），
            // 避免在 10 轮循环里对同一批失败 op 连打 10 次。
            if failed > 0 { return }
        }
    }

    // MARK: - pull（增量循环到追平）

    /// 返回是否落库成功（false = merge save 失败，本轮游标不推进、等下次重试）
    private func pullAndMerge() async throws -> Bool {
        for _ in 0..<Self.pullMaxRounds {
            let since = store.lastSeq
            let data = try await withAuth { atk in
                try await client.pull(accessToken: atk, sinceSeq: since)
            }
            let merged = merge(data)
            // 落库失败不得推进游标（否则 next since 越过这批变更，数据永久丢）
            guard merged else { return false }
            if data.serverSeq > since {
                store.lastSeq = data.serverSeq
            }
            let hasMore = !((data.favorites ?? []).isEmpty && (data.progress ?? []).isEmpty)
            if !hasMore || data.serverSeq <= since { return true }
        }
        return true
    }

    // MARK: - LWW 合并到 SwiftData

    /// 返回是否成功落库（false = save 失败，调用方不得推进 server_seq 游标）
    @discardableResult
    private func merge(_ data: SyncPullData) -> Bool {
        guard let ctx = modelContext else { return true }
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        for rec in data.favorites ?? [] {
            guard let ref = SyncBookKeyRef.parse(rec.bookKey) else { continue }
            let src = ref.source
            let albumId = ref.localAlbumId
            let fd = FetchDescriptor<FavoriteModel>(
                predicate: #Predicate { $0.src == src && $0.albumId == albumId })
            let local = (try? ctx.fetch(fd))?.first
            if rec.deleted == true {
                // 墓碑：云端删除晚于本地新增才删（晚删复活语义由服务端保证）
                if let local, (rec.lastClientAt ?? 0) > local.createdAt {
                    ctx.delete(local)
                }
            } else if let local {
                if (rec.lastClientAt ?? 0) > local.createdAt {
                    local.title = rec.title ?? local.title
                    local.author = rec.author ?? local.author
                    local.coverUrl = rec.coverUrl ?? local.coverUrl
                    local.detailPath = ref.localDetailPath
                }
            } else {
                ctx.insert(FavoriteModel(src: src, albumId: albumId,
                                         title: rec.title ?? "",
                                         author: rec.author, coverUrl: rec.coverUrl,
                                         detailPath: ref.localDetailPath,
                                         createdAt: rec.addedAt ?? now))
            }
        }

        for rec in data.progress ?? [] {
            guard let ref = SyncBookKeyRef.parse(rec.bookKey) else { continue }
            let src = ref.source
            let albumId = ref.localAlbumId
            let fd = FetchDescriptor<HistoryModel>(
                predicate: #Predicate { $0.src == src && $0.albumId == albumId })
            let local = (try? ctx.fetch(fd))?.first
            if rec.deleted == true {
                if let local, (rec.lastClientAt ?? 0) > local.updatedAt {
                    ctx.delete(local)
                }
            } else if let local {
                if (rec.updatedAt ?? 0) > local.updatedAt {
                    local.albumTitle = rec.title ?? local.albumTitle
                    local.coverUrl = rec.coverUrl ?? local.coverUrl
                    // build 51 · P0-1（质检必修）：云端 chapter_idx 是 0 基口径，
                    // 本地 HistoryModel.chapterIdx 按各源基底存（tingyou 1 基 / bili·易听书 0 基）。
                    // 直接赋值会让 tingyou 的 PC→iOS 续播稳定早一章（见 ChapterIdxNormalization 注释）。
                    if let ci = rec.chapterIdx {
                        local.chapterIdx = ChapterIdxNormalization.toLocal(src: src, cloudIdx: ci)
                    }
                    local.positionMs = max(0, rec.positionMs ?? local.positionMs)
                    local.durationMs = max(0, rec.durationMs ?? local.durationMs)
                    local.detailPath = ref.localDetailPath
                    local.updatedAt = rec.updatedAt ?? local.updatedAt
                }
            } else {
                ctx.insert(HistoryModel(src: src, albumId: albumId,
                                        albumTitle: rec.title ?? "",
                                        coverUrl: rec.coverUrl,
                                        // build 51 · P0-1：云端 0 基 → 本地源基底
                                        chapterIdx: ChapterIdxNormalization.toLocal(
                                            src: src, cloudIdx: rec.chapterIdx ?? 0),
                                        chapterTitle: "",
                                        positionMs: max(0, rec.positionMs ?? 0),
                                        durationMs: max(0, rec.durationMs ?? 0),
                                        detailPath: ref.localDetailPath,
                                        updatedAt: rec.updatedAt ?? now))
            }
        }
        // build 51 · P1-3（质检必修）：原 `try? ctx.save()` 把落库失败吞成 nil，
        // 合并结果没写进 SwiftData 却照常推进 lastSeq → 增量游标越过、数据永久丢。
        // 仓库约定「落库失败不允许静默」：这里必须记录（再抛给 pullAndMerge 终止本轮游标推进）。
        // build 52 · 条件 3：落库动作走可注入接缝——行为级用例注入抛错闭包，
        // 断言「save 抛错 → lastSeq 不推进」，不再靠字符串扫描守卫。
        do {
            if let commit = mergeCommit {
                try commit(ctx)
            } else {
                try ctx.save()
            }
        } catch {
            print("❌ sync merge save failed: \(error)")
            lastMessage = "本地数据写入失败，本轮同步已中止，下次会自动重试"
            return false
        }

        // 快照模式：本地独有数据（云端没有的收藏/进度）回传云端——首登上传本地存量
        if data.snapshotRequired == true {
            uploadLocalOnly(cloudKeys: Set((data.favorites ?? []).map(\.bookKey))
                            .union(Set((data.progress ?? []).map(\.bookKey))))
        }
        return true
    }

    /// 本地 bookKey 口径（与服务端 canonicalBookKey 一致：bili:bvid / src:bookId）
    private static func localBookKey(src: String, albumId: Int64, detailPath: String?) -> String {
        if src == SourceRegistry.BILI, let bvid = detailPath, !bvid.isEmpty {
            return "bili:\(bvid)"
        }
        return "\(src):\(albumId)"
    }

    private func uploadLocalOnly(cloudKeys: Set<String>) {
        guard let ctx = modelContext else { return }
        let favs = (try? ctx.fetch(FetchDescriptor<FavoriteModel>())) ?? []
        for f in favs {
            let key = Self.localBookKey(src: f.src, albumId: f.albumId, detailPath: f.detailPath)
            guard !cloudKeys.contains(key) else { continue }
            store.enqueueFavoriteUpsert(src: f.src, albumId: f.albumId, title: f.title,
                                        author: f.author, coverUrl: f.coverUrl,
                                        detailPath: f.detailPath)
        }
        let hist = (try? ctx.fetch(FetchDescriptor<HistoryModel>())) ?? []
        for h in hist {
            let key = Self.localBookKey(src: h.src, albumId: h.albumId, detailPath: h.detailPath)
            guard !cloudKeys.contains(key) else { continue }
            store.enqueueProgress(src: h.src, albumId: h.albumId, title: h.albumTitle,
                                  coverUrl: h.coverUrl,
                                  // build 51 · P0-1：本地源基底 → 云端 0 基
                                  chapterIdx: ChapterIdxNormalization.toCloud(
                                      src: h.src, localIndex: h.chapterIdx),
                                  positionMs: h.positionMs, durationMs: h.durationMs,
                                  detailPath: h.detailPath)
        }
        pendingOps = store.outboxCount
    }

    // MARK: - 错误文案（3 秒限制 / 首次建表超时的友好提示）

    /// build 52 · 条件 1：`errorDescription` 对 40002/40003/40004 是**固定**文案，
    /// 原实现直接 `return e.errorDescription ?? e.message` 会把携带真实原因
    /// 的 message（如「自动续期失败，请稍后重试」）丢掉，用户只看到同一句红字。
    /// 现在：有具体 message 且与固定文案不同 → 以「固定语义 + 具体原因」合并展示。
    private func friendlyMessage(_ error: Error) -> String {
        if let e = error as? SyncCloudError {
            let fixed = e.errorDescription
            guard let fixed, !e.message.isEmpty, e.message != fixed else {
                return fixed ?? e.message
            }
            return "\(fixed)（\(e.message)）"
        }
        if let e = error as? URLError {
            switch e.code {
            case .timedOut:
                return "云端响应超时：免费版云函数单次限 3 秒，首次登录时云端初始化建表可能超时，请稍等后重试"
            case .notConnectedToInternet:
                return "当前无网络连接：变更已在本机排队，联网后会自动补传"
            default:
                return "网络错误：变更已在本机排队，稍后会自动重试（\(e.localizedDescription)）"
            }
        }
        return "同步失败：变更已在本机排队，稍后会自动重试（\(error.localizedDescription)）"
    }
}
