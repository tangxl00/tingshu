import SwiftUI

struct SpeedSheet: View {
    @Binding var speed: Float
    let onSelect: (Float) -> Void
    @Environment(\.dismiss) private var dismiss
    let presets: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 3.5, 4.0]

    var body: some View {
        NavigationStack {
            List {
                ForEach(presets, id: \.self) { s in
                    let selected = abs(speed - s) < 0.01
                    // build 28 · 倍速整行可点：把对勾并入 Button label 内部，
                    // 替代原 `Button(文本)` + 外部 `.checkmark(selected)` 的组合——
                    // 后者把 Spacer/对勾放在 Button 之外，命中区只剩数字文本。
                    Button {
                        select(s)
                        // build 26（写入确认反馈）：选择后延迟关闭，让底部「当前：Xx」
                        // 的更新可见——面板内值变了而主界面按钮没变 = 视图刷新断裂；
                        // 面板内也不变 = 写入未执行。一层 UI 分辨两种故障。
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Text("\(String(format: "%.1f", s))x")
                                .foregroundStyle(selected ? Color.accentColor : .primary)
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    // 增强 4：按压反馈 + 选中高亮底色
                    .buttonStyle(.pressable)
                    .listRowBackground(
                        Group { if selected { Color.accentColor.opacity(0.12) } }
                    )
                }
            }
            // build 26（写入确认反馈）：底部常驻显示当前生效值（Binding 实时读）。
            .safeAreaInset(edge: .bottom) {
                Text("当前：\(String(format: "%.1f", speed))x")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .navigationTitle("播放速度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// build 22 · P1 修复：原按钮只调 onSelect 从不写 speed——而调用点传的 onSelect 是空闭包，
    /// Binding 的 set 永远不触发，倍速点了没反应。先写 Binding 再回调，双保险。
    /// （internal 供单测 @testable 调用：验证 Binding set 确实被触发；dismiss 留在按钮层，测试不触碰环境。）
    /// build 26：dismiss 从按钮层同步调用改为延迟 0.6s（见上）——写入路径本身不变，
    /// 既有 SpeedSheetBindingTests 语义不受影响。
    func select(_ s: Float) {
        speed = s
        onSelect(s)
    }
}

struct ChapterListSheet: View {
    let chapters: [Chapter]
    let currentIdx: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // 播放器章节面板对齐发现页书籍章节列表：当前播放章居中显示（上下都有章节），
            // 当前章后带音量标志，当前章之前的章节带 ✓。
            ScrollViewReader { proxy in
                List(chapters.indices, id: \.self) { i in
                    let isCurrent = i == currentIdx
                    let isListened = i < currentIdx
                    Button {
                        onSelect(i)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(chapters[i].index). \(chapters[i].title)")
                                    .font(.body)
                                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                                if let dur = chapters[i].durationSec {
                                    Text(Self.formatDuration(dur))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if isCurrent {
                                // 音量标志：与发现页书籍章节当前播放项一致（speaker.wave.3.fill）
                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityIdentifier("player_chapter_now_playing")
                            } else if isListened {
                                Image(systemName: "checkmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("player_chapter_done_\(chapters[i].index)")
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .listRowBackground(
                        Group { if isCurrent { Color.accentColor.opacity(0.12) } }
                    )
                    .id(i)
                }
                .onAppear {
                    guard chapters.indices.contains(currentIdx) else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(currentIdx, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle("章节列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private static func formatDuration(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return String(format: "%d:%02d", m, s)
    }
}
