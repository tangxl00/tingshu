import Foundation
import os

/// 诊断日志：内存 ring buffer + os.Logger 双写。
/// 真机排查要求：release（自签）构建下也能在 Console.app / 爱思助手「实时日志」里看到，
/// 因此统一走 os.Logger（unified logging），
/// print 只对 Xcode 调试会话可见，不能作为真机取证手段。
enum DiagLog {
    nonisolated(unsafe) private static var buffer: [(Date, String)] = []
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "com.tingyou.app.ios", category: "diag")

    static func mark(_ sender: Any, _ message: String) {
        let tag = String(describing: type(of: sender))
        let entry = (Date(), "[\(tag)] \(message)")
        lock.lock()
        buffer.append(entry)
        if buffer.count > 200 { buffer.removeFirst() }
        lock.unlock()
        // notice 级别：默认持久化且 Console.app 默认可见；
        // privacy: .public —— 自签分发没有调试器，隐私脱敏会显示 <private>，这里必须显式 public
        logger.notice("[\(tag, privacy: .public)] \(message, privacy: .public)")
    }

    static func recent() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.map { "\($0.0): \($0.1)" }
    }
}
