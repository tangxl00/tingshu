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
    ///
    /// build 53 · P1-3（复检 B1）：这个枚举是**续期维度**，不得再当通用失败通道。
    /// b52 曾把 push 部分失败、merge 落库失败等普通同步失败也写成
    /// `.retryScheduled`，界面于是显示「同步未完成，稍后自动重试」底下挂一句
    /// 续期口径文案——用户会以为令牌出了问题、去做重新登录这个无效动作。
    /// 现拆成两个维度：
    /// - `renewalState`（本枚举）：只描述**令牌续期**这件事（refreshing/retry/terminal）；
    /// - `syncFailure`（见 `SyncFailure`）：只描述**普通同步**（push/pull/落库）失败。
    /// 界面两行分别呈现，任何一侧失败都不影响另一侧显示。
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
        /// build 53 · 供持久化/跨事件判断：是否有未完成的续期动作
        var isActive: Bool {
            if case .idle = self { return false }
            return true
        }
    }

    /// build 53 · P1-3：普通同步失败维度（push 部分失败 / pull 或落库失败 /
    /// 传输层失败）。与 `RenewalState` 互不覆盖——一次失败只记到一个维度，
    /// 界面按维度分别展示，用户不会把「云端没确认某条变更」误读成「令牌过期」。
    enum SyncFailure: Equatable {
        /// 本轮全部成功（或无失败）
        case none
        /// 可自动恢复的同步失败（网络 / 5xx / 部分变更未确认 / 落库失败）
        case retryScheduled(String)
        /// 终局失败（已回未登录态等，同步本身不再继续）
        case terminal(String)

        var text: String? {
            switch self {
            case .none: return nil
            case .retryScheduled(let t), .terminal(let t): return t
            }
        }
        var isRetrying: Bool {
            if case .retryScheduled = self { return true }
            return false
        }
        var isTerminal: Bool {
            if case .terminal = self { return true }
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
    /// build 53 · P1-3：普通同步失败（push 部分失败 / pull / 落库 / 传输层）。
    /// 与 `renewalState` 是两个独立维度：续期正常而同步失败时此前会被写成
    /// 「续期」问题，用户看到「同步未完成」下面挂一句续期口气的文案，
    /// 会误以为要去重新登录（无效动作）。现已分离，界面各占一行。
    private(set) var syncFailure: SyncFailure = .none
    /// build 51 · P1-2：本轮 push 中被服务端判为 failed（非 success/duplicate）的 op 数
    private(set) var lastPushFailedCount = 0
    /// build 51 · P1-3：本轮 push 未能确认处理（缺 client_op_id / 未回 results）的 op 数
    private(set) var lastPushUnhandledCount = 0
    /// build 52 · 条件 2：当前已失败几次（退避阶梯下标），成功后归零
    private(set) var retryAttempt = 0
    /// build 53 · A1：是否处于前台（进后台是唯一允许停退避链的时机；此处仅作可观测状态）
    private(set) var isForeground = true

    private let client: SyncCloudClient
    private let store: SyncLocalStore
    private let modelContext: ModelContext?
    private var flushTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// build 53 · P1-3：本轮同步里**续期这一步**是否失败过。
    /// 只用 `renewalState.isRetrying` 判断会被上一轮残留状态误导（上一轮续期失败、
    /// 这一轮续期正常但 push 失败，仍会被归到续期维度）。此标记每轮 syncNow 归零，
    /// 只在 withAuth / renewAccessTokenInAdvance 的续期失败分支置真。
    private var renewalFailedThisRound = false

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
    /// - `renewalRetryHeadline` / `syncRetryHeadline` 描述可自动恢复的失败（不是成功态）；
    /// - `terminalHeadline` 必须明确「重新登录」——用户看到才知道点「立即同步」无用。
    ///
    /// build 53 · P1-3：文案也按维度分开。续期维度用「自动续期未成功」，
    /// 同步维度用「同步未完成」——b52 两个维度共用一句「同步未完成，稍后自动重试」，
    /// 挂在续期行下面，用户读到的潜台词就是「令牌出问题了，得重新登录」。
    static let refreshingHeadline = "正在自动续期…"
    static let renewalRetryHeadline = "自动续期未成功，稍后自动重试"
    static let terminalHeadline = "续期失败，请重新登录"
    /// build 53 · P1-3：普通同步（push 部分失败 / pull / 落库 / 传输层）维度
    static let syncRetryHeadline = "同步未完成，稍后自动重试"
    static let syncTerminalHeadline = "同步已中断，请重新登录"

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
                self.handleBecomeActive()
            }
        }
        // build 53 · A1（复检放行条件 A1）：退避链只允许在 App 真正进后台时停。
        // b52 的停链点是 AccountSyncScreen 的 .onDisappear——用户「看一眼、退回上一级」
        // （最常见的操作）就把退避链拆掉，而恢复入口只有 didBecomeActive
        //（用户没离开 App 就永不触发）→ 进页自愈在真机主路径上失效。
        // 现改为：进后台停（后台空转无意义，且 App 可能被挂起）；回前台/回页恢复。
        let backgroundObs = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.handleEnterBackground()
            }
        }
        observers = [outboxObs, activeObs, backgroundObs]
    }

    /// build 53 · A1：App 进后台——这是**唯一**允许停退避链的时机。
    /// 只取消在途定时器；失败意图（renewalState / syncFailure 的 retryScheduled）
    /// 保留，回前台由 `handleBecomeActive` 续挂。
    func handleEnterBackground() {
        isForeground = false
        guard phase == .loggedIn else { return }
        stopRetry()
    }

    /// build 53 · A1：回到前台——若本轮仍有未完成的失败意图、且没有在途重试任务，
    /// 立即续挂退避（不必等用户再进同步页）。随后走原有的「回前台补同步」逻辑。
    func handleBecomeActive() {
        isForeground = true
        guard phase == .loggedIn, store.isLoggedIn else { return }
        resumeRetryIfNeeded()
        refreshOnForeground()
    }

    /// 当前是否存在「已失败、待自动重试」的意图（两个维度任一）。
    /// 退出重试任务（进后台 / 手动同步开始）不改变意图，故它可跨事件保存。
    var hasPendingRetryIntent: Bool {
        renewalState.isRetrying || syncFailure.isRetrying
    }

    /// build 53 · A1：按失败意图续挂退避（同一时刻只挂一个；已有在途任务则不重复挂）。
    /// 非失败态不挂——避免把「已成功」误判成需要重试。
    func resumeRetryIfNeeded() {
        guard phase == .loggedIn, store.isLoggedIn, !syncing else { return }
        guard retryTask == nil, hasPendingRetryIntent else { return }
        scheduleRetry()
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
    ///
    /// build 53 · A2：进页即开启**新一轮**重试档位（`retryAttempt` 归零）。
    /// b52 的档位是「进程生命周期内累计失败次数」且 stopRetry 不碰计数——
    /// 用户进页看到失败、退出去、再回来（每轮都失败）会让档位跨轮继承，
    /// 4 次往返就饱和到 10 分钟档，红字反而挂得更久。改为按「本轮连续失败」
    /// 计档：进页归零、本轮内每次失败 +1、成功后归零。
    func onSyncPageEnter() async {
        guard phase == .loggedIn, store.isLoggedIn, !syncing else { return }
        // 进页 = 新一轮：档位归零（否则跨轮继承会提前饱和到 10 分钟档）
        retryAttempt = 0
        if needsProactiveRenewal(), await renewAccessTokenInAdvance() == false {
            return   // 提前续期失败：renewAccessTokenInAdvance 内已挂退避重试
        }
        await syncNow()
        // build 53 · A1：同步结束后若仍有失败意图却没有在途重试（例如进页时
        // 上一轮链已因进后台被停、本轮 syncNow 又因 guard 提前返回），
        // 这里补挂一次——「重新进页」同样是恢复入口。
        resumeRetryIfNeeded()
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
            renewalFailedThisRound = true
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
        // build 53 · P1-3：登出即清两个维度的失败态，避免下一账号看到上一账号的红字
        syncFailure = .none
        renewalFailedThisRound = false
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
        // build 53 · P1-3：本轮续期维度归零（否则上一轮的续期失败会把本轮
        // 普通同步失败也归到续期口径，界面又分不清两个维度）
        renewalFailedThisRound = false
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
                // 落库失败属可恢复（下次重试会再拉同一批），同样要挂退避重试。
                // build 53 · P1-3：属**同步**维度失败，不得写成续期状态。
                let text = lastMessage ?? "本地数据写入失败"
                syncFailure = .retryScheduled(text)
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
                // build 53 · P1-3：同样是**同步**维度失败（云端没确认变更），
                // 与令牌续期无关——用户不该被引导去重新登录。
                syncFailure = .retryScheduled(text)
                scheduleRetry()
                return
            }
            store.lastSyncAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            lastSyncAtMs = store.lastSyncAtMs
            lastMessage = nil
            renewalState = .idle
            syncFailure = .none
            retryAttempt = 0
        } catch {
            let text = friendlyMessage(error)
            lastMessage = text
            // 终局（已回未登录态）由 withAuth 内分派，此处不重复处理。
            // build 52 · 条件 1：withAuth 已在续期分支写入语义明确的
            // 「自动续期未成功：<真实原因>」——这里**不得再覆盖**成通用文案，
            // 否则界面又变回看不出「是续期失败还是普通同步失败」的同一句话。
            //
            // build 53 · P1-3：**按维度分流**——续期维度已有瞬态失败就只挂重试，
            // 不再往同步维度写一句重复文案；否则续期正常而普通同步失败，
            // 又被续期状态吞掉（b52 的「续期误用为通用失败通道」）。
            // 判据用**本轮**标记而不是 renewalState：renewalState 可能是上一轮
            // 遗留的 .retryScheduled，拿它判会把本轮普通同步失败误算成续期失败。
            if phase == .loggedIn {
                if renewalFailedThisRound {
                    // 续期维度已如实记录（withAuth / renewAccessTokenInAdvance 内写入），
                    // 同步维度保持无失败——两个维度不重复记账
                    syncFailure = .none
                } else {
                    syncFailure = .retryScheduled(text)
                }
                scheduleRetry()
            } else {
                // 已回落未登录：终局由 demoteToLoggedOut 的 renewalState = .terminal 呈现，
                // 同步维度不再重复写一句同样的红字
                syncFailure = .none
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
            renewalFailedThisRound = true
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
