import Foundation
import SwiftData

@Model
final class FavoriteModel {
    @Attribute(.unique) var src: String
    @Attribute(.unique) var albumId: Int64
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
}

@Model
final class ImportedBookModel {
    @Attribute(.unique) var id: Int64
    var title: String
    var kind: String
    var createdAt: Int64

    init(id: Int64 = 0, title: String, kind: String,
         createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.id = id; self.title = title; self.kind = kind; self.createdAt = createdAt
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
