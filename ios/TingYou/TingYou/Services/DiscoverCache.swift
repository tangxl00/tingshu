import Foundation

// build 21 · 反馈 4/6：DiscoverDataLoading 协议与 CombinedDiscoverLoader 组合实现
// 已移至 DiscoverViewModel.swift 同文件维护（协议新增 discoverCategory 后，
// AlbumRepository 单独遵循不再成立——tingyou 分类与 HTML 源分类走不同出口）。

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
/// - build 24（存量 P2）：`validKeyPrefixes` 非空时 init 一次性清理孤儿缓存文件
///   （build 21 多源键 `<src>|<section>` 在 build 22 固定主源后不再被读写，
///   仅 2MB 超限才会按最旧淘汰——正常使用下永不清除，缓存目录膨胀）；
/// - 不涉及网络与证书锚点会话（纯本地文件，与安全组件无交互）。
final class DiskDiscoverCache: DiscoverCacheStore, @unchecked Sendable {
    private let dir: URL
    private let lock = NSLock()
    private let maxTotalBytes: Int

    init(directory: URL? = nil, maxTotalBytes: Int = 2 * 1024 * 1024, validKeyPrefixes: [String]? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiscoverCache", isDirectory: true)
        self.dir = base
        self.maxTotalBytes = maxTotalBytes
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let prefixes = validKeyPrefixes, !prefixes.isEmpty {
            pruneSections(keepingKeyPrefixes: prefixes)
        }
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

    /// build 24（存量 P2）：一次性清理旧缓存键孤儿文件——只保留键命中任一合法前缀的
    /// `rank-*.json`，其余（build 21 多源键如 `ting15|玄幻` 等）删除；
    /// 非 rank-*.json 形态的文件（目录元数据等）不动。内部持锁，仅 init 调用。
    private func pruneSections(keepingKeyPrefixes prefixes: [String]) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            guard f.lastPathComponent.hasPrefix("rank-"), f.pathExtension == "json" else { continue }
            let key = String(f.deletingPathExtension().lastPathComponent.dropFirst("rank-".count))
            if !prefixes.contains(where: { key.hasPrefix($0) }) {
                try? fm.removeItem(at: f)
            }
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
