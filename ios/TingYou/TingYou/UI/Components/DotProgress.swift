import SwiftUI

struct DotProgress: View {
    let value: Double
    let onSeek: (Double) -> Void
    @State private var dragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray4))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, min(w, w * (dragging ? dragValue : value))), height: 4)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 16, height: 16)
                    .offset(x: max(0, min(w - 16, w * (dragging ? dragValue : value) - 8)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        dragValue = max(0, min(1, g.location.x / w))
                    }
                    .onEnded { g in
                        let final = max(0, min(1, g.location.x / w))
                        dragValue = final
                        dragging = false
                        onSeek(final)
                    }
            )
        }
    }
}
