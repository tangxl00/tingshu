import UIKit
import ObjectiveC

/// build 45 · 反馈 4：全局「点搜索框以外任何地方」收起键盘。
/// 方案：window 级 UITapGestureRecognizer(target: window,
/// action: #selector(UIView.endEditing(_:)))，cancelsTouchesInView = false。
/// 关键差异（相对 b43/b44 被证伪的 SwiftUI 容器手势路线）：
/// - 容器级 SwiftUI tap 手势会抢占 List 行内 NavigationLink 激活
///   （build 42 CI 六用例证据：点书=收焦+无导航）；
/// - window 级 UIKit recognizer + cancelsTouchesInView=false 不吞事件——
///   命中行点击时事件照常传递给 List，行导航正常激活，收焦只是伴随动作。
/// recognizer delegate 跳过命中 UITextField/UITextView 的 tap（点搜索框
/// 本身不触发收起，避免「先收再聚焦」的键盘闪烁）。
/// 本方案替代并删除 b43/b44 的五处局部手势挂载；scrollDismissesKeyboard 保留。
private var tapRecognizerKey: UInt8 = 0

extension UIWindow {
    func installGlobalTapToDismissKeyboard() {
        guard objc_getAssociatedObject(self, &tapRecognizerKey) == nil else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(UIView.endEditing(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = KeyboardDismissSkipTextInputs.shared
        addGestureRecognizer(tap)
        objc_setAssociatedObject(self, &tapRecognizerKey, tap, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

/// 跳过命中文本输入控件的 tap：返回 false 表示 recognizer 不响应该触摸。
private final class KeyboardDismissSkipTextInputs: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissSkipTextInputs()

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard let hitView = touch.view else { return true }
        var current: UIView? = hitView
        while let view = current {
            if view is UITextField || view is UITextView { return false }
            current = view.superview
        }
        return true
    }

    /// build 45 · CI 第一轮（反馈 4 修复）：并行识别——window 级 recognizer
    /// 必须与 SwiftUI 交互控件（Button/DisclosureGroup/Menu/NavigationLink 行）
    /// 的内部手势同时识别。缺这条时控件手势独占认领、window recognizer 被排除，
    /// endEditing 永不触发——CI 证据：旧 G（非交互空白区）过、C（「分类」交互
    /// 控件）与新 G 交互点位败。cancelsTouchesInView=false 已保证不吞事件，
    /// 并行识别只补「识别权」不补「事件权」，行导航照常。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

enum GlobalKeyboardDismiss {
    private static var installed = false

    /// 幂等安装：App 启动时调用一次。SwiftUI WindowGroup 的 window 在
    /// App.init 之后才创建，故除当前已建窗口外还监听 didBecomeKeyNotification
    /// 兜底后续新 window（每次回调按关联对象去重，不会重复挂载）。
    static func installOnce() {
        guard !installed else { return }
        installed = true
        installOnConnectedWindows()
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            installOnConnectedWindows()
        }
    }

    private static func installOnConnectedWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.installGlobalTapToDismissKeyboard()
            }
        }
    }
}
