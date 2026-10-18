import Foundation

struct RankResponse: Codable {
    let detail: String?
    let generatedAt: Int64?
    let group: String?
    let hasMore: Bool?
    let items: [AlbumDto]
    let page: Int?
    let pageSize: Int?
    let total: Int?
}

struct CategoryResponse: Codable {
    let data: [AlbumDto]
    let page: Int?
    let pages: Int?
    let detail: String?
}

struct ChaptersResponse: Codable {
    let id: Int64?
    let available: Bool?
    let chapters: [ChapterDto]
    let count: Int?
    let detail: String?
}

struct FiltersResponse: Codable {
    let sorts: [SortDto]
    let categories: [CategoryFilterDto]
    let statuses: [StatusFilterDto]
    let detail: String?
}

struct SearchRequest: Codable {
    let keyword: String
    let page: Int
}

struct SearchResponse: Codable {
    let detail: String?
    let hasMore: Bool?
    let results: [AlbumDto]
    let total: Int?
}

struct PlayResponse: Codable {
    let playUrl: String?
}

struct AlbumDto: Codable {
    let id: Int64
    let title: String?
    let author: String?
    let teller: String?
    let coverUrl: String?
    let intro: String?
    let description: String?
    let synopsis: String?
    let playCount: Int64?
    let recommendAt: Int64?
    let status: Int?
    let count: Int?
    let cat: String?
    let catId: Int?
    let type: String?
    let typeId: Int?
    let updatedAt: Int64?
    let shelfStatus: Int?
    let available: Bool?
}

struct ChapterDto: Codable {
    let id: Int64
    let index: Int
    let title: String?
    let duration: Int?
}

struct SortDto: Codable { let key: String?; let name: String? }
struct TypeFilterDto: Codable { let id: Int?; let name: String? }
struct CategoryFilterDto: Codable { let id: Int?; let name: String?; let types: [TypeFilterDto]? }
struct StatusFilterDto: Codable { let key: Int?; let name: String? }

extension AlbumDto {
    func toDomain(source: String = "tingyou") -> Album {
        Album(
            albumId: id,
            title: title ?? "",
            author: author,
            teller: teller,
            coverUrl: coverUrl,
            intro: intro ?? description ?? synopsis,
            category: cat,
            categoryId: catId,
            type: type,
            typeId: typeId,
            status: status,
            chapterCount: count,
            updatedAt: updatedAt,
            playCount: playCount,
            available: available,
            source: source,
            detailPath: nil
        )
    }
}

extension ChapterDto {
    func toDomain() -> Chapter {
        Chapter(chapterId: id, index: index, title: title ?? "", durationSec: duration)
    }
}

extension FiltersResponse {
    func toDomain() -> Filters {
        Filters(
            sorts: sorts.map { FilterSort(key: $0.key ?? "", name: $0.name ?? "") },
            categories: categories.map { c in
                FilterCategory(
                    id: c.id ?? 0,
                    name: c.name ?? "",
                    types: (c.types ?? []).map { FilterType(id: $0.id ?? 0, name: $0.name ?? "") }
                )
            },
            statuses: statuses.map { FilterStatus(key: $0.key ?? 0, name: $0.name ?? "") }
        )
    }
}
