import Foundation
import SwiftData

actor ImportService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func importLinks(title: String, links: [(url: String, title: String?)]) async throws -> Int64 {
        // build 20 必修 3：写入侧分配真实递增 id（fetch 现有最大 id + 1），
        // 替代旧的默认 id=0（配合已删除的 .unique 约束，第二本书必冲突）。
        let maxId = try modelContext.fetch(
            FetchDescriptor<ImportedBookModel>(sortBy: [SortDescriptor(\.id, order: .reverse)])
        ).first?.id ?? 0
        let book = ImportedBookModel(id: maxId + 1, title: title, kind: "userlink")
        modelContext.insert(book)
        do {
            try modelContext.save()
        } catch {
            // 落库失败不允许静默：打日志后继续抛给调用方提示用户
            print("importLinks book save failed [\(title)]: \(error)")
            throw error
        }
        let bookId = book.id
        for (idx, link) in links.enumerated() {
            let ch = ImportedChapterModel(bookId: bookId, chapterIdx: idx + 1, title: link.title ?? "第\(idx+1)集", uri: link.url)
            modelContext.insert(ch)
        }
        do {
            try modelContext.save()
        } catch {
            print("importLinks chapters save failed [\(title)]: \(error)")
            throw error
        }
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
