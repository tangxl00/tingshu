import SwiftUI
import UIKit

/// 封面图（增强 5.2）：改为经 CoverImageCache（内存 + 20MB 磁盘 URLCache）加载，
/// 替代 AsyncImage 默认无磁盘缓存的行为。
struct CoverImage: View {
    let url: String?
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "book.closed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            guard let url, let u = URL(string: url) else { return }
            image = await CoverImageCache.shared.image(for: u)
        }
        .frame(width: size, height: size)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
