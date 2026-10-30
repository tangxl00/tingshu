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

    private(set) var phase: Phase = .loggedOut
    private(set) var email: String?
    private(set) var syncing = false
    private(set) var lastSyncAtMs: Int64 = 0
    private(set) var pendingOps = 0
    private(set) var lastMessage: String?

    private let client: SyncCloudClient
    private let store: SyncLocalStore
    private let modelContext: ModelContext?
    private var flushTask: Task<Void, Never>?
    /// deinit 是 nonisolated 上下文，@MainActor 隔离的存储属性不能直接读；
    /// 观察者 token 只在主线程写入/读取，nonisolated(unsafe) 标注该事实。
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    /// push 客户端分片（契约 push_client_chunk=100；服务端硬上限 500）
    static let pushChunk = 100
    /// pull 增量分页循环上限（每页 100 条变更，防异常死循环）
    static let pullMaxRounds = 10

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
        guard stale || store.outboxCount > 0 else { return }
        Task { await syncNow() }
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
    }

    // MARK: - 全量同步（push → pull → 快照回传的本地独有数据再 push）

    func syncNow() async {
        guard !syncing else { return }
        guard phase == .loggedIn, store.isLoggedIn else { return }
        syncing = true
        defer { syncing = false; pendingOps = store.outboxCount }
        do {
            try await pushOutbox()
            try await pullAndMerge()
            if store.outboxCount > 0 {
                try await pushOutbox()
            }
            store.lastSyncAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            lastSyncAtMs = store.lastSyncAtMs
            lastMessage = nil
        } catch {
            lastMessage = friendlyMessage(error)
        }
    }

    // MARK: - 鉴权包装（40003 refresh 重试一次；40002 清凭据）

    private func withAuth<T>(_ work: (_ accessToken: String) async throws -> T) async throws -> T {
        guard var cred = store.loadCredentials() else {
            throw SyncCloudError(code: 40002, message: "未登录")
        }
        do {
            return try await work(cred.accessToken)
        } catch let e as SyncCloudError where e.code == 40003 {
            do {
                let refreshed = try await client.refresh(refreshToken: cred.refreshToken)
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                cred.accessToken = refreshed.accessToken
                cred.refreshToken = refreshed.refreshToken
                cred.accessExpireAtMs = now + Int64(refreshed.accessExpireIn) * 1000
                cred.refreshExpireAtMs = now + Int64(refreshed.refreshExpireIn) * 1000
                store.saveCredentials(cred)
                return try await work(cred.accessToken)
            } catch let e2 as SyncCloudError where e2.code == 40002 {
                // refresh 轮换后旧 rtk 二次使用即废 → 回未登录态
                store.resetForLogout()
                phase = .loggedOut
                email = nil
                lastMessage = "登录状态已失效，请重新登录"
                throw e2
            } catch {
                // 网络 / 超时等：保留凭据，下次再试
                throw SyncCloudError(code: 40003, message: "自动续期失败，请稍后重试")
            }
        } catch let e as SyncCloudError where e.code == 40002 {
            store.resetForLogout()
            phase = .loggedOut
            email = nil
            lastMessage = "登录状态已失效，请重新登录"
            throw e
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
            // 只有拿到结果的 op 才算处理完（服务端 2s deadline 内未完成的留队列重推，
            // op_dedup 7 天幂等保证重放不重复计数）
            let done = (data.results ?? []).compactMap(\.clientOpId)
            guard !done.isEmpty else { return }
            store.removeOutbox(opIds: done)
            if let seq = data.serverSeq, seq > store.lastSeq {
                store.lastSeq = seq
            }
            if store.outboxCount == 0 { return }
        }
    }

    // MARK: - pull（增量循环到追平）

    private func pullAndMerge() async throws {
        for _ in 0..<Self.pullMaxRounds {
            let since = store.lastSeq
            let data = try await withAuth { atk in
                try await client.pull(accessToken: atk, sinceSeq: since)
            }
            merge(data)
            if data.serverSeq > since {
                store.lastSeq = data.serverSeq
            }
            let hasMore = !((data.favorites ?? []).isEmpty && (data.progress ?? []).isEmpty)
            if !hasMore || data.serverSeq <= since { return }
        }
    }

    // MARK: - LWW 合并到 SwiftData

    private func merge(_ data: SyncPullData) {
        guard let ctx = modelContext else { return }
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
                    local.chapterIdx = rec.chapterIdx ?? local.chapterIdx
                    local.positionMs = max(0, rec.positionMs ?? local.positionMs)
                    local.durationMs = max(0, rec.durationMs ?? local.durationMs)
                    local.detailPath = ref.localDetailPath
                    local.updatedAt = rec.updatedAt ?? local.updatedAt
                }
            } else {
                ctx.insert(HistoryModel(src: src, albumId: albumId,
                                        albumTitle: rec.title ?? "",
                                        coverUrl: rec.coverUrl,
                                        chapterIdx: rec.chapterIdx ?? 0,
                                        chapterTitle: "",
                                        positionMs: max(0, rec.positionMs ?? 0),
                                        durationMs: max(0, rec.durationMs ?? 0),
                                        detailPath: ref.localDetailPath,
                                        updatedAt: rec.updatedAt ?? now))
            }
        }
        try? ctx.save()

        // 快照模式：本地独有数据（云端没有的收藏/进度）回传云端——首登上传本地存量
        if data.snapshotRequired == true {
            uploadLocalOnly(cloudKeys: Set((data.favorites ?? []).map(\.bookKey))
                            .union(Set((data.progress ?? []).map(\.bookKey))))
        }
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
                                  coverUrl: h.coverUrl, chapterIdx: h.chapterIdx,
                                  positionMs: h.positionMs, durationMs: h.durationMs,
                                  detailPath: h.detailPath)
        }
        pendingOps = store.outboxCount
    }

    // MARK: - 错误文案（3 秒限制 / 首次建表超时的友好提示）

    private func friendlyMessage(_ error: Error) -> String {
        if let e = error as? SyncCloudError {
            return e.errorDescription ?? e.message
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
