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
                    Button("\(String(format: "%.1f", s))x") {
                        onSelect(s)
                        dismiss()
                    }
                    .checkmark(selected)
                    // 增强 4：按压反馈 + 选中高亮底色
                    .buttonStyle(.pressable)
                    .listRowBackground(
                        Group { if selected { Color.accentColor.opacity(0.12) } }
                    )
                }
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
}

struct ChapterListSheet: View {
    let chapters: [Chapter]
    let currentIdx: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(chapters.indices, id: \.self) { i in
                let isCurrent = i == currentIdx
                Button {
                    onSelect(i)
                    dismiss()
                } label: {
                    HStack {
                        Text("\(chapters[i].index). \(chapters[i].title)")
                            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                        Spacer()
                        if isCurrent {
                            Image(systemName: "waveform")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                // 增强 4：按压反馈 + 当前播放项高亮底色
                .buttonStyle(.pressable)
                .listRowBackground(
                    Group { if isCurrent { Color.accentColor.opacity(0.12) } }
                )
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
}
