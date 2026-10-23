import SwiftUI
import SwiftData

// build 29 · 59听书网导入页。
// 流程：粘贴详情页链接 → 解析预览（书名/播音/作者/章节列表）→ 确认导入 → 跳专辑页。
// 合规提示常驻页面：仅流式收听、不落盘。

struct Ting59ImportScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var modelContext
    @State private var input = ""
    @State private var isResolving = false
    @State private var isImporting = false
    @State private var preview: Ting59Preview? = nil
    @State private var errorMessage: String? = nil
    @State private var importedBookId: Int64? = nil

    let onBack: () -> Void
    let onOpenAlbum: (String, Int64) -> Void
    var prefillBookId: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let bookId = importedBookId, let preview = preview {
                        importDoneView(bookId: bookId, preview: preview)
                    } else {
                        importInputView
                    }
                }
                .padding()
            }
            .navigationTitle("59听书网导入")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                    }
                }
            }
        }
        .onAppear {
            if let bookId = prefillBookId {
                input = "https://www.ting59.com/mp3/\(bookId).html"
                resolve(bookId: bookId)
            }
        }
    }

    // MARK: - 导入完成

    @ViewBuilder
    private func importDoneView(bookId: Int64, preview: Ting59Preview) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 24)
            Text("已导入《\(preview.title)》（\(preview.chapters.count) 集）")
                .font(.title3)
            HStack(spacing: 12) {
                Button("继续导入") {
                    reset()
                }
                .buttonStyle(.bordered)
                Button("打开专辑") {
                    onOpenAlbum(SourceRegistry.TING59, bookId)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 输入与预览

    @ViewBuilder
    private var importInputView: some View {
        Text("粘贴 59听书网书籍详情页链接（如 https://www.ting59.com/mp3/19745.html），导入后在线收听。")
            .font(.body)
            .foregroundStyle(.secondary)

        TextField("书籍链接", text: $input)
            .textFieldStyle(.roundedBorder)

        Button {
            if let bookId = Ting59InputParser.parse(input) {
                resolve(bookId: bookId)
            } else {
                errorMessage = "无法识别链接，请粘贴 59听书网详情页链接"
            }
        } label: {
            HStack {
                Image(systemName: "book.fill")
                Text("解析")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(input.isEmpty || isResolving || isImporting)

        Divider()

        if isResolving {
            HStack {
                ProgressView()
                Text("解析中…")
            }
        } else if let preview = preview {
            previewView(preview)
        } else if let error = errorMessage {
            Text(error)
                .foregroundStyle(.red)
                .font(.callout)
        }

        Spacer().frame(height: 16)
        Text("合规说明：本功能仅以流式方式在线收听，不下载、不缓存到磁盘。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func previewView(_ preview: Ting59Preview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.title).font(.headline)
            if let narrator = preview.narrator {
                Text("播音：\(narrator)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let author = preview.author {
                Text("作者：\(author)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let category = preview.category {
                Text("类型：\(category)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("共 \(preview.chapters.count) 集：")
                .font(.caption)
            ForEach(preview.chapters.prefix(5), id: \.index) { ch in
                Text("· \(ch.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if preview.chapters.count > 5 {
                Text("… 等共 \(preview.chapters.count) 集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("取消") { reset() }
                    .buttonStyle(.bordered)
                Button("导入为听书") { confirmImport(preview) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 操作

    private func resolve(bookId: String) {
        isResolving = true
        errorMessage = nil
        preview = nil
        Task {
            do {
                let adapter = Ting59Adapter()
                let detail = try await adapter.bookDetail(bookId: bookId)
                preview = Ting59Preview(
                    title: detail.book.title,
                    author: detail.book.author,
                    narrator: detail.book.narrator,
                    category: detail.book.category,
                    chapters: detail.chapters,
                    description: detail.description,
                    siteBookId: bookId
                )
            } catch {
                errorMessage = "解析失败：\(error.localizedDescription)"
            }
            isResolving = false
        }
    }

    private func confirmImport(_ preview: Ting59Preview) {
        isImporting = true
        Task {
            do {
                let bookId = try await importTing59Book(preview: preview)
                importedBookId = bookId
            } catch {
                errorMessage = "导入失败：\(error.localizedDescription)"
            }
            isImporting = false
        }
    }

    private func importTing59Book(preview: Ting59Preview) async throws -> Int64 {
        // P1-4：查重以站点 bookId（meta）为准，避免同名不同书或同书改名导致的问题
        let existingDescriptor = FetchDescriptor<ImportedBookModel>(
            predicate: #Predicate { $0.kind == Ting59Source.KIND }
        )
        let existing = (try? modelContext.fetch(existingDescriptor)) ?? []
        if let dup = existing.first(where: { $0.meta == preview.siteBookId }) {
            // 已存在，更新章节
            try await updateTing59Chapters(bookId: dup.id, chapters: preview.chapters)
            return dup.id
        }

        // 新建
        let maxIdDescriptor = FetchDescriptor<ImportedBookModel>(
            sortBy: [SortDescriptor(\.id, order: .reverse)]
        )
        let maxId = (try? modelContext.fetch(maxIdDescriptor).first?.id) ?? 0
        let newId = maxId + 1

        let book = ImportedBookModel(
            id: newId,
            title: preview.title,
            kind: Ting59Source.KIND,
            meta: preview.siteBookId
        )
        modelContext.insert(book)

        // P0-3：章节 URI 中存储站点 bookId，供 PlaybackRepository 播放时解析
        for ch in preview.chapters {
            let uri = Ting59Source.buildChapterUri(bookId: preview.siteBookId, playIndex: ch.index)
            let chapter = ImportedChapterModel(
                bookId: newId,
                chapterIdx: ch.index,
                title: ch.title,
                uri: uri
            )
            modelContext.insert(chapter)
        }

        try modelContext.save()
        return newId
    }

    private func updateTing59Chapters(bookId: Int64, chapters: [Ting59Adapter.Ting59Chapter]) async throws {
        // 取回站点 bookId 用于构建 URI
        let bookDescriptor = FetchDescriptor<ImportedBookModel>(
            predicate: #Predicate { $0.id == bookId }
        )
        let siteBookId = (try? modelContext.fetch(bookDescriptor).first?.meta) ?? String(bookId)

        let descriptor = FetchDescriptor<ImportedChapterModel>(
            predicate: #Predicate { $0.bookId == bookId }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        for old in existing {
            modelContext.delete(old)
        }
        for ch in chapters {
            let uri = Ting59Source.buildChapterUri(bookId: siteBookId, playIndex: ch.index)
            let chapter = ImportedChapterModel(
                bookId: bookId,
                chapterIdx: ch.index,
                title: ch.title,
                uri: uri
            )
            modelContext.insert(chapter)
        }
        try modelContext.save()
    }

    private func reset() {
        input = ""
        preview = nil
        errorMessage = nil
        importedBookId = nil
        isResolving = false
        isImporting = false
    }
}

// MARK: - 预览模型

private struct Ting59Preview: Sendable {
    let title: String
    let author: String?
    let narrator: String?
    let category: String?
    let chapters: [Ting59Adapter.Ting59Chapter]
    let description: String?
    let siteBookId: String
}
