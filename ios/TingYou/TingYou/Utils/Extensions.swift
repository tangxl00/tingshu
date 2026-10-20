import Foundation
import SwiftUI

extension String {
    var trimmed: String { self.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - 统一按压反馈（增强 4：选择类控件按压态视觉反馈）

/// 统一按钮按压样式：按下时轻微缩放 + 透明度降低，松开回弹。
/// 只表达「按压中」；「选中」由各控件的选中态样式（高亮底色/对勾/着色）表达，两者可区分。
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    var pressedOpacity: Double = 0.65

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? pressedOpacity : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// 全局统一按压反馈：外观模式选项 / 音源选择 / 倍速选项 / 章节列表等选择类控件使用
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}
