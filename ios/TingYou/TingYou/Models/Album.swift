import Foundation

struct Album: Identifiable, Hashable, Sendable {
    let albumId: Int64
    let title: String
    let author: String?
    let teller: String?
    let coverUrl: String?
    let intro: String?
    let category: String?
    let categoryId: Int?
    let type: String?
    let typeId: Int?
    let status: Int?
    let chapterCount: Int?
    let updatedAt: Int64?
    let playCount: Int64?
    let available: Bool?
    let source: String
    let detailPath: String?

    var id: Int64 { albumId }
}

struct Chapter: Identifiable, Hashable, Sendable {
    let chapterId: Int64
    let index: Int
    let title: String
    let durationSec: Int?

    var id: Int64 { chapterId }
}

struct PagedResult<T>: Sendable {
    let items: [T]
    let hasMore: Bool
}

struct FilterSort: Sendable { let key: String; let name: String }
struct FilterType: Sendable { let id: Int; let name: String }
struct FilterCategory: Sendable { let id: Int; let name: String; let types: [FilterType] }
struct FilterStatus: Sendable { let key: Int; let name: String }
struct Filters: Sendable {
    let sorts: [FilterSort]
    let categories: [FilterCategory]
    let statuses: [FilterStatus]
}
