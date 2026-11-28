import SwiftUI

/// 全局播放器打开动作。
///
/// 专辑页从「发现 / 书架 / 搜索」多处推入，逐层透传闭包会污染中间页面签名。
/// 这里用 SwiftUI Environment 注入 ContentView 的 `$showPlayer`，
/// 使任意子页面（当前为 AlbumScreen）点章后可直接唤起播放器 sheet。
private struct OpenPlayerKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openPlayer: () -> Void {
        get { self[OpenPlayerKey.self] }
        set { self[OpenPlayerKey.self] = newValue }
    }
}
