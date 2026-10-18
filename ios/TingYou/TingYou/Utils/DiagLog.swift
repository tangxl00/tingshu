import Foundation

enum DiagLog {
    private static var buffer: [(Date, String)] = []
    private static let lock = NSLock()

    static func mark(_ sender: Any, _ message: String) {
        let entry = (Date(), "[\(type(of: sender))] \(message)")
        lock.lock()
        buffer.append(entry)
        if buffer.count > 200 { buffer.removeFirst() }
        lock.unlock()
        print(entry.1)
    }

    static func recent() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.map { "\($0.0): \($0.1)" }
    }
}
