import Foundation
import SwiftData

@Model
final class FavoriteModel {
    // build 19 P1-1：删除原 src / albumId 上的两个 @Attribute(.unique)——
    // SwiftData 的 .unique 是逐属性独立唯一而非 (src, albumId) 组合唯一，
    // 导致同一音源收藏第二本书触发约束冲突、save 抛错被吞而静默丢失。
    // (src, albumId) 的逻辑唯一由 AlbumRepository.addFavorite 的 fetch 守卫保证。
    var src: String
    var albumId: Int64
    var title: String
    var author: String?
    var teller: String?
    var coverUrl: String?
    var chapterCount: Int?
    var status: Int?
    var lastChapterIdx: Int?
    var detailPath: String?
    var createdAt: Int64

    init(src: String, albumId: Int64, title: String, author: String? = nil,
         teller: String? = nil, coverUrl: String? = nil, chapterCount: Int? = nil,
         status: Int? = nil, lastChapterIdx: Int? = nil, detailPath: String? = nil,
         createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.src = src; self.albumId = albumId; self.title = title
        self.author = author; self.teller = teller; self.coverUrl = coverUrl
        self.chapterCount = chapterCount; self.status = status
        self.lastChapterIdx = lastChapterIdx; self.detailPath = detailPath
        self.createdAt = createdAt
    }
    func toAlbum() -> Album {
        Album(albumId: albumId, title: title, author: author, teller: teller,
              coverUrl: coverUrl, intro: nil, category: nil, categoryId: nil,
              type: nil, typeId: nil, status: status, chapterCount: chapterCount,
              updatedAt: nil, playCount: nil, available: nil, source: src,
              detailPath: detailPath)
    }

}

@Model
final class HistoryModel {
    var src: String
    var albumId: Int64
    var albumTitle: String
    var coverUrl: String?
    var chapterIdx: Int
    var chapterTitle: String
    var positionMs: Int64
    var durationMs: Int64
    var detailPath: String?
    var updatedAt: Int64

    init(src: String, albumId: Int64, albumTitle: String, coverUrl: String? = nil,
         chapterIdx: Int, chapterTitle: String, positionMs: Int64, durationMs: Int64,
         detailPath: String? = nil,
         updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.src = src; self.albumId = albumId; self.albumTitle = albumTitle
        self.coverUrl = coverUrl; self.chapterIdx = chapterIdx
        self.chapterTitle = chapterTitle; self.positionMs = positionMs
        self.durationMs = durationMs; self.detailPath = detailPath
        self.updatedAt = updatedAt
    }
    func toAlbum() -> Album {
        Album(albumId: albumId, title: albumTitle, author: nil, teller: nil,
              coverUrl: coverUrl, intro: nil, category: nil, categoryId: nil,
              type: nil, typeId: nil, status: nil, chapterCount: nil,
              updatedAt: updatedAt, playCount: nil, available: nil, source: src,
              detailPath: detailPath)
    }

}

@Model
final class ImportedBookModel {
    // build 20 必修 3：删除 @Attribute(.unique) var id 并去掉 init 默认 id=0——
    // 与 build 19 修的 FavoriteModel 同型问题：SwiftData 的 .unique 是逐属性唯一，
    // 配合默认 id=0，第二本导入书必然触发约束冲突。
    // id 唯一性改由写入侧（ImportService.importLinks fetch 最大 id + 1）保证。
    // build 29：新增 meta 字段（nullable String，lightweight migration 自动支持），
    // 用于存储 B站 UP主名 / ting59 播音·作者 等扩展信息。
    var id: Int64
    var title: String
    var kind: String
    var meta: String?
    var createdAt: Int64

    init(id: Int64, title: String, kind: String, meta: String? = nil,
         createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.id = id; self.title = title; self.kind = kind; self.meta = meta; self.createdAt = createdAt
    }
}

@Model
final class ImportedChapterModel {
    var bookId: Int64
    var chapterIdx: Int
    var title: String
    var uri: String

    init(bookId: Int64, chapterIdx: Int, title: String, uri: String) {
        self.bookId = bookId; self.chapterIdx = chapterIdx
        self.title = title; self.uri = uri
    }
}
