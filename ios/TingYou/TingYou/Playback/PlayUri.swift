import Foundation

enum PlayUri {
    static func build(src: String, albumId: Int64, chapterIdx: Int) -> String {
        return "tingyou-chapter://play?src=\(src)&album_id=\(albumId)&chapter_idx=\(chapterIdx)"
    }

    static func parse(_ uri: String) -> (src: String, albumId: Int64, chapterIdx: Int)? {
        guard let url = URL(string: uri),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // build 36 返修（r4 · 崩溃面加固）：uniqueKeysWithValues 遇重复 query 键是
        // 进程击杀级 fatal error（"Duplicate keys in dictionary"）——本函数在
        // resourceLoader 首行处理 AVFoundation 递来的 URL，畸形重复键不再炸进程；
        // 正常构造的 URI 键唯一，取首个出现键，行为不变。
        let q = Dictionary(comps.queryItems?.compactMap { ($0.name, $0.value ?? "") } ?? [],
                           uniquingKeysWith: { first, _ in first })
        guard let src = q["src"],
              let aid = Int64(q["album_id"] ?? ""),
              let cidx = Int(q["chapter_idx"] ?? "") else { return nil }
        return (src, aid, cidx)
    }
}
