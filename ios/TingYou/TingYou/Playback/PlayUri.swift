import Foundation

enum PlayUri {
    static func build(src: String, albumId: Int64, chapterIdx: Int) -> String {
        return "tingyou-chapter://play?src=\(src)&album_id=\(albumId)&chapter_idx=\(chapterIdx)"
    }

    static func parse(_ uri: String) -> (src: String, albumId: Int64, chapterIdx: Int)? {
        guard let url = URL(string: uri),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let q = Dictionary(uniqueKeysWithValues: comps.queryItems?.compactMap { ($0.name, $0.value ?? "") } ?? [])
        guard let src = q["src"],
              let aid = Int64(q["album_id"] ?? ""),
              let cidx = Int(q["chapter_idx"] ?? "") else { return nil }
        return (src, aid, cidx)
    }
}
