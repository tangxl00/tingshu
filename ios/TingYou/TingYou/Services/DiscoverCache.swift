import Foundation

/// 发现页数据源出口（增强 5.1）：抽协议便于单测注入假数据源验证「优先读缓存」路径。
protocol DiscoverDataLoading: Sendable {
    func loadRank(section: String, page: Int) async throws -> PagedResult<Album>
}

/// AlbumRepository 天然满足发现页数据源出口（rank 即首页榜单加载）。
extension AlbumRepository: DiscoverDataLoading {
    func loadRank(section: String, page: Int) async throws -> PagedResult<Album> {
        try await rank(section: section, page: page)
    }
}

/// 发现页本地缓存出口（增强 5.1）：启动先渲染上次缓存、后台静默刷新替换。
protocol DiscoverCacheStore: Sendable {
    /// 写入某分区第 1 页数据
    func saveSection(_ section: String, albums: [Album]) throws
    /// 读取某分区缓存（未命中返回 nil）
    func loadSection(_ section: String) -> [Album]?
    /// 清空全部缓存
    func removeAll()
}

/// 发现页磁盘缓存（JSON 文件落地 Caches/DiscoverCache/）：
/// - 单文件按分区存储（recommend / new / hot / serial / story 各一份）；
/// - 总量上限 2MB，超限按最旧修改时间淘汰；
/// - 不涉及网络与证书锚点会话（纯本地文件，与安全组件无交互）。
final class DiskDiscoverCache: DiscoverCacheStore, @unchecked Sendable {
    private let dir: URL
    private let lock = NSLock()
    private let maxTotalBytes: Int

    init(directory: URL? = nil, maxTotalBytes: Int = 2 * 1024 * 1024) {
        let base = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiscoverCache", isDirectory: true)
        self.dir = base
        self.maxTotalBytes = maxTotalBytes
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func saveSection(_ section: String, albums: [Album]) throws {
        let data = try JSONEncoder().encode(albums)
        lock.lock()
        defer { lock.unlock() }
        try data.write(to: fileURL(section), options: .atomic)
        evictIfNeededLocked()
    }

    func loadSection(_ section: String) -> [Album]? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL(section)) else { return nil }
        return try? JSONDecoder().decode([Album].self, from: data)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
    }

    // MARK: - 内部

    private func fileURL(_ section: String) -> URL {
        // 分区名做文件名安全化（当前分区均为 ASCII 字母，防御性处理）
        let safe = section.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("rank-\(safe).json")
    }

    /// 大小控制：磁盘总量超限时按最旧修改时间淘汰（须持锁调用）
    private func evictIfNeededLocked() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        for f in files {
            let values = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = values?.fileSize ?? 0
            let date = values?.contentModificationDate ?? .distantPast
            entries.append((f, date, size))
            total += size
        }
        guard total > maxTotalBytes else { return }
        for e in entries.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: e.url)
            total -= e.size
            if total <= maxTotalBytes { break }
        }
    }
}
