import SwiftUI
import UIKit

/// 封面图（增强 5.2）：改为经 CoverImageCache（内存 + 20MB 磁盘 URLCache）加载，
/// 替代 AsyncImage 默认无磁盘缓存的行为。
struct CoverImage: View {
    let url: String?
    let size: CGFloat
    /// build 20 必修 1：封面所属专辑的音源（防盗链 Referer 按源取值；nil 走旧全局查找）。
    var source: String? = nil

    @State private var image: UIImage?

    init(url: String?, size: CGFloat, source: String? = nil) {
        self.url = url
        self.size = size
        self.source = source
    }

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
            image = await CoverImageCache.shared.image(for: u, source: source)
        }
        .frame(width: size, height: size)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
