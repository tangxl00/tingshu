import Foundation

/// build 50 · 云同步本地状态：凭据 / last_seq / outbox（UserDefaults 持久化）。
/// 线程安全（NSLock）：AlbumRepository（actor）入队与 SyncEngine（MainActor）冲刷并发访问。
/// outbox 语义（对齐 PC 端）：
///   - 断网 / 未登录时操作排队，联网且已登录后自动补传
///   - 同 (entity, bookKey) 只保留最后一条（批内压缩，防进度 5s 节流入队撑爆）
///   - client_op_id UUID → 服务端 7 天幂等，重放不会重复计数
final class SyncLocalStore: @unchecked Sendable {
    static let shared = SyncLocalStore()

    static let outboxChangedNotification = Notification.Name("tingshuSyncOutboxChanged")

    private let defaults: UserDefaults
    private let lock = NSLock()

    private enum Key {
        static let credentials = "tingshu_sync_credentials"
        static let lastSeq = "tingshu_sync_last_seq"
        static let outbox = "tingshu_sync_outbox"
        static let deviceId = "tingshu_sync_device_id"
        static let lastSyncAt = "tingshu_sync_last_at"
    }

    /// outbox 上限（契约服务端单次 500 / 客户端分片 100；900 = 9 个分片，
    /// 覆盖首登快照回传本地存量的常见规模，超出丢最旧的）
    static let outboxCap = 900

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 设备 id（首访生成，80 字符内，服务端 client_device 匹配用）

    func deviceId() -> String {
        lock.lock(); defer { lock.unlock() }
        if let id = defaults.string(forKey: Key.deviceId), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Key.deviceId)
        return id
    }

    // MARK: - 凭据

    struct Credentials: Codable, Equatable {
        var accessToken: String
        var refreshToken: String
        var userId: String
        var email: String
        var deviceId: String
        var accessExpireAtMs: Int64
        var refreshExpireAtMs: Int64
    }

    func loadCredentials() -> Credentials? {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Key.credentials) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    func saveCredentials(_ c: Credentials) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(c) {
            defaults.set(data, forKey: Key.credentials)
        }
    }

    func clearCredentials() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Key.credentials)
    }

    var isLoggedIn: Bool { loadCredentials() != nil }

    // MARK: - last_seq（pull 游标）

    var lastSeq: Int64 {
        get {
            lock.lock(); defer { lock.unlock() }
            return Int64(defaults.integer(forKey: Key.lastSeq))
        }
        set {
            lock.lock(); defer { lock.unlock() }
            defaults.set(Int(newValue), forKey: Key.lastSeq)
        }
    }

    // MARK: - 上次同步时间

    var lastSyncAtMs: Int64 {
        get {
            lock.lock(); defer { lock.unlock() }
            return Int64(defaults.double(forKey: Key.lastSyncAt))
        }
        set {
            lock.lock(); defer { lock.unlock() }
            defaults.set(Double(newValue), forKey: Key.lastSyncAt)
        }
    }

    // MARK: - outbox

    func loadOutbox() -> [SyncPushOp] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Key.outbox) else { return [] }
        return (try? JSONDecoder().decode([SyncPushOp].self, from: data)) ?? []
    }

    /// 入队（同实体同 bookKey 压缩保留最后一条；只登录后入队）
    func enqueue(_ op: SyncPushOp) {
        lock.lock()
        var ops = (defaults.data(forKey: Key.outbox)).flatMap { try? JSONDecoder().decode([SyncPushOp].self, from: $0) } ?? []
        let target = "\(op.entity)|\(op.payload.album?.source ?? "")|\(op.payload.album?.bookId ?? op.payload.album?.bvid ?? "")"
        ops.removeAll { existing in
            let t = "\(existing.entity)|\(existing.payload.album?.source ?? "")|\(existing.payload.album?.bookId ?? existing.payload.album?.bvid ?? "")"
            return t == target
        }
        ops.append(op)
        if ops.count > Self.outboxCap {
            ops.removeFirst(ops.count - Self.outboxCap)
        }
        if let data = try? JSONEncoder().encode(ops) {
            defaults.set(data, forKey: Key.outbox)
        }
        lock.unlock()
        NotificationCenter.default.post(name: Self.outboxChangedNotification, object: nil)
    }

    /// 取前 n 条（分片冲刷用）
    func takeOutboxChunk(max: Int) -> [SyncPushOp] {
        lock.lock(); defer { lock.unlock() }
        let ops = (defaults.data(forKey: Key.outbox)).flatMap { try? JSONDecoder().decode([SyncPushOp].self, from: $0) } ?? []
        return Array(ops.prefix(max))
    }

    /// 冲刷成功后按 client_op_id 移除
    func removeOutbox(opIds: [String]) {
        lock.lock(); defer { lock.unlock() }
        var ops = (defaults.data(forKey: Key.outbox)).flatMap { try? JSONDecoder().decode([SyncPushOp].self, from: $0) } ?? []
        let ids = Set(opIds)
        let before = ops.count
        ops.removeAll { ids.contains($0.clientOpId) }
        guard ops.count != before else { return }
        if let data = try? JSONEncoder().encode(ops) {
            defaults.set(data, forKey: Key.outbox)
        }
    }

    var outboxCount: Int {
        lock.lock(); defer { lock.unlock() }
        let ops = (defaults.data(forKey: Key.outbox)).flatMap { try? JSONDecoder().decode([SyncPushOp].self, from: $0) } ?? []
        return ops.count
    }

    func clearOutbox() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Key.outbox)
    }

    // MARK: - 登出清理（凭据 + 游标 + outbox；不动本地收藏/历史数据）

    func resetForLogout() {
        clearCredentials()
        clearOutbox()
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Key.lastSeq)
        defaults.removeObject(forKey: Key.lastSyncAt)
    }
}

// MARK: - 业务入队辅助（AlbumRepository / SyncEngine 共用）

extension SyncLocalStore {
    private func albumPayload(src: String, albumId: Int64, detailPath: String?) -> SyncOpAlbum {
        if src == SourceRegistry.BILI, let bvid = detailPath, !bvid.isEmpty {
            return SyncOpAlbum(source: src, bookId: nil, bvid: bvid)
        }
        return SyncOpAlbum(source: src, bookId: String(albumId), bvid: nil)
    }

    private func newOpId() -> String { UUID().uuidString }

    /// 收藏 upsert（本地书架 + 云端）
    func enqueueFavoriteUpsert(src: String, albumId: Int64, title: String,
                               author: String?, coverUrl: String?, detailPath: String?) {
        guard isLoggedIn else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        enqueue(SyncPushOp(
            clientOpId: newOpId(), entity: "favorite", op: "upsert", clientAt: now,
            payload: SyncOpPayload(
                album: albumPayload(src: src, albumId: albumId, detailPath: detailPath),
                title: title, author: author, coverUrl: coverUrl,
                addedAt: now, chapterIdx: nil, positionMs: nil, durationMs: nil, updatedAt: nil)))
    }

    /// 收藏删除（墓碑由服务端落，90 天）
    func enqueueFavoriteDelete(src: String, albumId: Int64, detailPath: String?) {
        guard isLoggedIn else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        enqueue(SyncPushOp(
            clientOpId: newOpId(), entity: "favorite", op: "delete", clientAt: now,
            payload: SyncOpPayload(
                album: albumPayload(src: src, albumId: albumId, detailPath: detailPath),
                title: nil, author: nil, coverUrl: nil,
                addedAt: nil, chapterIdx: nil, positionMs: nil, durationMs: nil, updatedAt: nil)))
    }

    /// 播放进度 upsert（recordHistory 节流调用，outbox 批内压缩兜底）
    func enqueueProgress(src: String, albumId: Int64, title: String, coverUrl: String?,
                         chapterIdx: Int, positionMs: Int64, durationMs: Int64, detailPath: String?) {
        guard isLoggedIn else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        enqueue(SyncPushOp(
            clientOpId: newOpId(), entity: "progress", op: "upsert", clientAt: now,
            payload: SyncOpPayload(
                album: albumPayload(src: src, albumId: albumId, detailPath: detailPath),
                title: title, author: nil, coverUrl: coverUrl,
                addedAt: nil, chapterIdx: chapterIdx, positionMs: positionMs,
                durationMs: durationMs, updatedAt: now)))
    }
}
