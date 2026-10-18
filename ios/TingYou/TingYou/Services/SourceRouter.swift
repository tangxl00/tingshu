import Foundation

actor SourceRouter {
    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    func search(src: String, keyword: String) async throws -> [Album] {
        switch src {
        case SourceRegistry.TINGYOU:
            let result = try await AlbumRepository(apiClient: apiClient)
                .search(keyword: keyword, page: 1)
            return result.items
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func albumDetail(src: String, albumId: Int64, detailPath: String? = nil) async throws -> Album {
        switch src {
        case SourceRegistry.TINGYOU:
            let repo = AlbumRepository(apiClient: apiClient)
            return try await repo.albumDetail(id: albumId)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func chapters(src: String, albumId: Int64, detailPath: String? = nil) async throws -> [Chapter] {
        switch src {
        case SourceRegistry.TINGYOU:
            let repo = AlbumRepository(apiClient: apiClient)
            return try await repo.chapters(albumId: albumId)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func playUrl(src: String, albumId: Int64, chapterIdx: Int, detailPath: String? = nil) async throws -> String {
        switch src {
        case SourceRegistry.TINGYOU:
            let repo = AlbumRepository(apiClient: apiClient)
            return try await repo.playUrl(albumId: albumId, chapterIdx: chapterIdx)
        default:
            throw URLError(.unsupportedURL)
        }
    }
}
