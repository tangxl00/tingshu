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
                    Button("\(String(format: "%.1f", s))x") {
                        onSelect(s)
                        dismiss()
                    }
                    .checkmark(abs(speed - s) < 0.01)
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
                Button {
                    onSelect(i)
                    dismiss()
                } label: {
                    HStack {
                        Text("\(chapters[i].index). \(chapters[i].title)")
                            .foregroundStyle(i == currentIdx ? .tint : .primary)
                        Spacer()
                        if i == currentIdx {
                            Image(systemName: "waveform")
                                .foregroundStyle(.tint)
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
}
