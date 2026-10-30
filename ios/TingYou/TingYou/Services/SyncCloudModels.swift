import Foundation

/// build 50 · 云同步（契约 v1.0.0，与 PC 端 v1.1.13 同一套 tingshu-sync 云函数）。
/// 本文件：契约 DTO + 错误码 + 统一信封。字段名以已部署云函数实现为准（snake_case 经
/// JSONDecoder.convertFromSnakeCase / JSONEncoder.convertToSnakeCase 转换）。
///
/// 错误码口径（任务约定）：
///   40002 = 未登录 / refresh_token 无效（清凭据回未登录态）
///   40003 = access_token 过期（客户端 refresh 后重试一次）
///   50001 = 服务内部错误（含 SMTP 未配置；免费版 3s 窗口首次建表可能超时 → 友好重试提示）
///   50002 = 资源不存在
///   其余：10001 验证码无效 / 10002 验证码过期 / 10003 发送过频 / 10004 设备超限 /
///         42901 限流（60 次/分钟）
struct SyncCloudError: Error, LocalizedError {
    let code: Int
    let message: String

    var errorDescription: String? {
        switch code {
        case 10001: return "验证码无效，请检查后重输"
        case 10002: return "验证码已过期，请重新获取"
        case 10003: return "验证码发送太频繁，请稍后再试"
        case 10004: return "绑定设备数量超限（20 台）"
        case 42901: return "云端请求过于频繁（60 次/分钟），请稍后再试"
        case 40002: return "登录状态已失效，请重新登录"
        case 40003: return "登录状态已过期，正在自动续期"
        case 50001: return "云端服务内部错误：若是首次登录，云端初始化建表可能超过 3 秒限制，请稍等后重试"
        case 50002: return "云端资源不存在"
        default: return "云端错误(\(code))：\(message)"
        }
    }
}

/// 统一响应信封 { code, message, data, request_id }
struct SyncEnvelope<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?
}

// MARK: - 请求体

struct SyncCodeRequest: Encodable {
    let email: String
}

struct SyncLoginRequest: Encodable {
    let email: String
    let code: String
    let deviceId: String
    let deviceName: String
    let platform: String
}

struct SyncRefreshRequest: Encodable {
    let refreshToken: String
}

struct SyncPullRequest: Encodable {
    let sinceSeq: Int64
}

struct SyncPushRequest: Encodable {
    let ops: [SyncPushOp]
}

// MARK: - push op（outbox 持久化单元）

/// 契约 §6 op：{ client_op_id, entity, op, client_at, payload }
/// iOS 端只推 favorite / progress 两类实体（设置项不同步，iOS 无对应设置源）。
struct SyncPushOp: Codable, Equatable {
    let clientOpId: String
    let entity: String      // "favorite" | "progress"
    let op: String          // "upsert" | "delete"
    let clientAt: Int64
    var payload: SyncOpPayload
}

/// op payload（字段按实体裁剪，可选字段编码时 nil 省略）。
struct SyncOpPayload: Codable, Equatable {
    var album: SyncOpAlbum?
    var title: String?
    var author: String?
    var coverUrl: String?
    var addedAt: Int64?
    var chapterIdx: Int?
    var positionMs: Int64?
    var durationMs: Int64?
    var updatedAt: Int64?
}

/// 契约 §3.1 album 定位：bili 走 bvid（本地 bookId 恒为哈希值，服务端只认 bvid），
/// 其余 source 走 book_id（数字串 1-20 位）。album_key 由服务端拼接，客户端不自拼。
struct SyncOpAlbum: Codable, Equatable {
    var source: String
    var bookId: String?
    var bvid: String?
}

// MARK: - 响应 data

struct SyncConfigData: Decodable {
    let mode: String
    let contractVersion: String?
    let sources: [String]?
    let smtpConfigured: Bool?
    let secretConfigured: Bool?
}

struct SyncCodeData: Decodable {
    let expireIn: Int?
    let resendIn: Int?
    let delivered: String?
}

struct SyncUserData: Decodable {
    let userId: String
    let email: String
    let createdAt: Int64?
}

struct SyncLoginData: Decodable {
    let accessToken: String
    let accessExpireIn: Int
    let refreshToken: String
    let refreshExpireIn: Int
    let user: SyncUserData
    let deviceId: String
}

struct SyncRefreshData: Decodable {
    let accessToken: String
    let accessExpireIn: Int
    let refreshToken: String
    let refreshExpireIn: Int
}

struct SyncMeData: Decodable {
    let user: SyncUserData?
    let deviceId: String?
    let devicesCount: Int?
    let maxDevices: Int?
    let serverTime: Int64?
}

/// pull 返回：快照（snapshot_required=true）时三数组为全量；增量时为本次变更。
struct SyncPullData: Decodable {
    let serverSeq: Int64
    let sinceSeq: Int64?
    let snapshotRequired: Bool?
    let favorites: [SyncFavoriteRecord]?
    let progress: [SyncProgressRecord]?
}

/// 云端收藏记录（快照 / 增量条目同构）
struct SyncFavoriteRecord: Decodable {
    let bookKey: String
    let source: String
    let title: String?
    let author: String?
    let coverUrl: String?
    let addedAt: Int64?
    let lastClientAt: Int64?
    let deleted: Bool?
    let deletedAt: Int64?
}

/// 云端进度记录
struct SyncProgressRecord: Decodable {
    let bookKey: String
    let source: String
    let title: String?
    let coverUrl: String?
    let chapterIdx: Int?
    let positionMs: Int64?
    let durationMs: Int64?
    let updatedAt: Int64?
    let lastClientAt: Int64?
    let deleted: Bool?
}

struct SyncPushResultItem: Decodable {
    let clientOpId: String?
    let status: String?
    let bookKey: String?
}

struct SyncPushData: Decodable {
    let serverSeq: Int64?
    let results: [SyncPushResultItem]?
    let processed: Int?
    let submitted: Int?
}

// MARK: - bookKey 解析（服务端拼的 "src:id" / "bili:bvid"，客户端只拆不拼）

struct SyncBookKeyRef {
    let source: String
    /// bili：bvid；其余：数字串 bookId
    let identifier: String
    /// 本地 SwiftData 用的 albumId（bili 由 bvid 稳定哈希得到，与 SourceRouter 口径一致）
    var localAlbumId: Int64 {
        if source == SourceRegistry.BILI {
            return SourceRouter.biliAlbumId(from: identifier)
        }
        return Int64(identifier) ?? 0
    }
    /// 本地 detailPath（bili 存 bvid，其余与远端 identifier 相同）
    var localDetailPath: String { identifier }

    static func parse(_ key: String) -> SyncBookKeyRef? {
        guard let idx = key.firstIndex(of: ":") else { return nil }
        let src = String(key[key.startIndex..<idx])
        let ident = String(key[key.index(after: idx)...])
        guard !src.isEmpty, !ident.isEmpty else { return nil }
        return SyncBookKeyRef(source: src, identifier: ident)
    }
}
