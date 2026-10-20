import XCTest
import SwiftData
@testable import TingYou

/// build 20 必修 3 回归：导入书写入侧分配真实递增 id，
/// 两本书均落库（旧实现默认 id=0 + @Attribute(.unique)，第二本必冲突）。
final class ImportServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var service: ImportService!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: FavoriteModel.self, HistoryModel.self,
            ImportedBookModel.self, ImportedChapterModel.self,
            configurations: config)
        service = await MainActor.run {
            ImportService(modelContext: self.container.mainContext)
        }
    }

    /// 判别力：旧实现第二本导入书触发 unique(id=0) 约束冲突 → importLinks 抛错，本测试必失败。
    func testImportTwoBooksBothPersistWithDistinctIds() async throws {
        let id1 = try await service.importLinks(
            title: "第一本", links: [("https://example.com/a1.mp3", "第1集")])
        let id2 = try await service.importLinks(
            title: "第二本", links: [("https://example.com/b1.mp3", "第1集")])

        let books = try await MainActor.run {
            try self.container.mainContext.fetch(FetchDescriptor<ImportedBookModel>())
        }
        XCTAssertEqual(books.count, 2, "两本导入书都应落库（旧实现第二本被 unique 冲突吞掉）")
        XCTAssertEqual(Set(books.map(\.id)).count, 2, "id 互不相同")
        XCTAssertGreaterThan(id1, 0, "id 应为真实递增值，不再是默认 0")
        XCTAssertGreaterThan(id2, id1, "第二本书 id 递增")
        XCTAssertEqual(Set(books.map(\.title)), ["第一本", "第二本"])
    }

    /// 章节必须挂到各自书籍的 bookId 上（导入列表互不串台）。
    func testChaptersLinkedToCorrectBook() async throws {
        let id1 = try await service.importLinks(
            title: "书A", links: [("https://example.com/a1.mp3", "A1"), ("https://example.com/a2.mp3", "A2")])
        let id2 = try await service.importLinks(
            title: "书B", links: [("https://example.com/b1.mp3", "B1")])

        let chaptersA = try await service.chapters(for: id1)
        let chaptersB = try await service.chapters(for: id2)
        XCTAssertEqual(chaptersA.map(\.title), ["A1", "A2"])
        XCTAssertEqual(chaptersB.map(\.title), ["B1"])
    }

    /// 导入失败必须抛错（不允许静默）：链接列表为空也照常建书（0 章）。
    func testImportEmptyLinksCreatesBookWithZeroChapters() async throws {
        let id = try await service.importLinks(title: "空书", links: [])
        XCTAssertGreaterThan(id, 0)
        let chapters = try await service.chapters(for: id)
        XCTAssertTrue(chapters.isEmpty)
    }
}
