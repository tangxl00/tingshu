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
        /// build 51 · P1-3：溢出淘汰记账键（原静默 removeFirst，无痕迹）
        static let dropped = "tingshu_sync_outbox_dropped"
        static let droppedDelete = "tingshu_sync_outbox_dropped_delete"
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
            // build 51 · P1-3：溢出淘汰必须优先保住 delete（墓碑）——删除一旦被挤掉，
            // 云端永远收不到墓碑，条目在重新登录 / 新设备全量拉取后复活（P0-2 同源缺陷）。
            // 淘汰顺序：先淘汰非 delete 的最旧项；仍超限才淘汰最旧的 delete（并告警计数）。
            let overflow = ops.count - Self.outboxCap
            var dropIds = Set<String>()
            var remaining = overflow
            for existing in ops where remaining > 0 {
                guard existing.op != "delete" else { continue }
                dropIds.insert(existing.clientOpId)
                remaining -= 1
            }
            var deleteDropped = 0
            if remaining > 0 {
                for existing in ops where remaining > 0 {
                    guard existing.op == "delete", !dropIds.contains(existing.clientOpId) else { continue }
                    dropIds.insert(existing.clientOpId)
                    remaining -= 1
                    deleteDropped += 1
                }
            }
            ops = ops.filter { !dropIds.contains($0.clientOpId) }
            recordOverflowDrop(total: dropIds.count, deleteDropped: deleteDropped)
        }
        if let data = try? JSONEncoder().encode(ops) {
            defaults.set(data, forKey: Key.outbox)
        }
        lock.unlock()
        NotificationCenter.default.post(name: Self.outboxChangedNotification, object: nil)
    }

    /// 溢出淘汰计数（P1-3：静默丢改可见记账）。写入注入的 UserDefaults，便于验收与排障。
    private func recordOverflowDrop(total: Int, deleteDropped: Int) {
        guard total > 0 else { return }
        let note = deleteDropped > 0
            ? "（含 \(deleteDropped) 条 delete 墓碑：已无 upsert 可淘汰，属容量不足的极端场景）"
            : ""
        print("⚠️ outbox overflow: 淘汰 \(total) 条 op\(note)")
        let prev = defaults.integer(forKey: Key.dropped)
        defaults.set(prev + total, forKey: Key.dropped)
        if deleteDropped > 0 {
            let prevDel = defaults.integer(forKey: Key.droppedDelete)
            defaults.set(prevDel + deleteDropped, forKey: Key.droppedDelete)
        }
    }

    /// 溢出淘汰累计计数（验收 / 排障用；0 表示从未发生容量淘汰）。
    var droppedOpsTotal: Int {
        lock.lock(); defer { lock.unlock() }
        return defaults.integer(forKey: Key.dropped)
    }

    /// 其中 delete 墓碑被淘汰的累计条数（正常应为 0）。
    var droppedDeleteTotal: Int {
        lock.lock(); defer { lock.unlock() }
        return defaults.integer(forKey: Key.droppedDelete)
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

    /// 播放进度删除（墓碑）——build 51 · P0-2：书架滑删 / 清空历史必须走这里。
    /// 云端契约：progress 实体同样支持 `op: "delete"`，服务端在记录不存在时也落墓碑
    /// （防「本地删了、云端还在」→ 重新登录全量拉取后复活）。
    /// payload 只需 album（bookKey 由服务端 canonicalBookKey 拼），其余字段留空。
    func enqueueProgressDelete(src: String, albumId: Int64, detailPath: String?) {
        guard isLoggedIn else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        enqueue(SyncPushOp(
            clientOpId: newOpId(), entity: "progress", op: "delete", clientAt: now,
            payload: SyncOpPayload(
                album: albumPayload(src: src, albumId: albumId, detailPath: detailPath),
                title: nil, author: nil, coverUrl: nil,
                addedAt: nil, chapterIdx: nil, positionMs: nil, durationMs: nil, updatedAt: nil)))
    }
}
