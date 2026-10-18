import Foundation
import SwiftData

actor ImportService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func importLinks(title: String, links: [(url: String, title: String?)]) async throws -> Int64 {
        let book = ImportedBookModel(title: title, kind: "userlink")
        modelContext.insert(book)
        try modelContext.save()
        let bookId = book.id
        for (idx, link) in links.enumerated() {
            let ch = ImportedChapterModel(bookId: bookId, chapterIdx: idx + 1, title: link.title ?? "第\(idx+1)集", uri: link.url)
            modelContext.insert(ch)
        }
        try modelContext.save()
        return bookId
    }

    func importedBooks() throws -> [ImportedBookModel] {
        let descriptor = FetchDescriptor<ImportedBookModel>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try modelContext.fetch(descriptor)
    }

    func chapters(for bookId: Int64) throws -> [ImportedChapterModel] {
        let descriptor = FetchDescriptor<ImportedChapterModel>(
            predicate: #Predicate { $0.bookId == bookId },
            sortBy: [SortDescriptor(\.chapterIdx)]
        )
        return try modelContext.fetch(descriptor)
    }
}
