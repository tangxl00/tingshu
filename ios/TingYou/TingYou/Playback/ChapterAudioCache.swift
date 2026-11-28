import Foundation

/// 后续章节音频的本地预缓存。
///
/// 设计要点：
/// - 只缓存整章音频文件，文件名由占位 URI 稳定派生；
/// - 使用现有 proxySession 下载，保留 B站 CDN 的 Referer/UA 与证书固定口径；
/// - 最多保留 10 个文件 / 300MB，按最后修改时间淘汰最旧条目；
/// - 下载中写入 .part，完成后原子改名，避免半文件被误命中。
final class ChapterAudioCache {
    static let shared = ChapterAudioCache()

    static let maxFiles = 10
    static let maxBytes: Int64 = 300 * 1024 * 1024

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var inFlight: [String: Task<URL?, Never>] = [:]

    private init() {}

    /// 文件名净化：占位 URI 含 scheme / 冒号 / 斜杠，直接做文件名不安全。
    static func sanitizedFileName(forKey key: String) -> String {
        let replaced = key.replacingOccurrences(
            of: "[^A-Za-z0-9_.-]",
            with: "_",
            options: .regularExpression
        )
        return String(replaced.prefix(180)) + ".m4a"
    }

    private var rootDirectory: URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ChapterAudioPrefetch", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 命中返回本地文件 URL；未命中返回 nil。
    func cachedFileURL(forKey key: String) -> URL? {
        let url = rootDirectory.appendingPathComponent(Self.sanitizedFileName(forKey: key))
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 后台预取一章。重复 key 复用同一 Task，避免并发重复下载。
    func prefetch(key: String, request: URLRequest, session: URLSession) async -> URL? {
        if let existing = cachedFileURL(forKey: key) { return existing }

        lock.lock()
        if let running = inFlight[key] {
            lock.unlock()
            return await running.value
        }
        let task = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            let dest = self.rootDirectory.appendingPathComponent(Self.sanitizedFileName(forKey: key))
            let partial = dest.deletingLastPathComponent()
                .appendingPathComponent(dest.lastPathComponent + ".part")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    try? self.fileManager.removeItem(at: partial)
                    return nil
                }
                try data.write(to: partial, options: .atomic)
                if self.fileManager.fileExists(atPath: dest.path) {
                    try? self.fileManager.removeItem(at: dest)
                }
                try self.fileManager.moveItem(at: partial, to: dest)
                self.prune()
                return dest
            } catch {
                try? self.fileManager.removeItem(at: partial)
                return nil
            }
        }
        inFlight[key] = task
        lock.unlock()

        let result = await task.value
        lock.lock()
        inFlight.removeValue(forKey: key)
        lock.unlock()
        return result
    }

    /// 容量淘汰：先按数量，再按总字节数；始终淘汰最旧文件。
    private func prune() {
        lock.lock()
        defer { lock.unlock() }
        let contents = (try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles)) ?? []
        var entries = contents.compactMap { url -> (url: URL, date: Date, size: Int64)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate else { return nil }
            return (url, date, Int64(values.fileSize ?? 0))
        }
        entries.sort { $0.date > $1.date }

        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        while entries.count > Self.maxFiles, let oldest = entries.popLast() {
            try? fileManager.removeItem(at: oldest.url)
            total -= oldest.size
        }
        var index = entries.count - 1
        while total > Self.maxBytes, index >= 0 {
            let oldest = entries[index]
            try? fileManager.removeItem(at: oldest.url)
            total -= oldest.size
            index -= 1
        }
    }
}
