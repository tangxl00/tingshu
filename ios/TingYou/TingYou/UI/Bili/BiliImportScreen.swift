import SwiftUI
import SwiftData

// build 29 · B站导入页。
// 流程：粘贴链接/短链/BV号 → 解析预览（标题/UP主/分P列表）→ 确认导入 → 跳专辑页。
// 合规提示常驻页面：仅流式收听、不落盘；付费/大会员/充电专属只提示不绕过。

struct BiliImportScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var modelContext
    @State private var input = ""
    @State private var isResolving = false
    @State private var isImporting = false
    @State private var preview: BiliPreview? = nil
    @State private var errorMessage: String? = nil
    @State private var importedBookId: Int64? = nil

    let onBack: () -> Void
    let onOpenAlbum: (String, Int64) -> Void
    var prefillBvid: String? = nil

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
            .navigationTitle("B站导入")
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
            if let bvid = prefillBvid {
                input = bvid
                resolve(bvid: bvid)
            }
        }
    }

    // MARK: - 导入完成

    @ViewBuilder
    private func importDoneView(bookId: Int64, preview: BiliPreview) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 24)
            Text("已导入《\(preview.title)》（\(preview.pageTitles.count) 集）")
                .font(.title3)
            HStack(spacing: 12) {
                Button("继续导入") {
                    reset()
                }
                .buttonStyle(.bordered)
                Button("打开专辑") {
                    onOpenAlbum(SourceRegistry.BILI, bookId)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 输入与预览

    @ViewBuilder
    private var importInputView: some View {
        Text("粘贴B站视频链接（支持 b23.tv 短链、BV 号、av 号），导入后按分P收听音频轨。")
            .font(.body)
            .foregroundStyle(.secondary)

        TextField("视频链接 / BV 号", text: $input)
            .textFieldStyle(.roundedBorder)

        Button {
            resolve(bvid: input)
        } label: {
            HStack {
                Image(systemName: "video.fill")
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
        Text("合规说明：本功能仅以流式方式在线收听视频的音频轨，不下载、不缓存到磁盘；付费、大会员、充电专属内容未登录时无法收听，App 仅提示失败，不提供任何绕过。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func previewView(_ preview: BiliPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.title).font(.headline)
            Text("UP主：\(preview.upName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("共 \(preview.pageTitles.count) 个分P（章节）：")
                .font(.caption)
            ForEach(preview.pageTitles.prefix(5), id: \.self) { title in
                Text("· \(title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if preview.pageTitles.count > 5 {
                Text("… 等共 \(preview.pageTitles.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if preview.paid {
                Text(BiliSource.paidImportRejectMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 4)
            } else {
                HStack(spacing: 12) {
                    Button("取消") { reset() }
                        .buttonStyle(.bordered)
                    Button("导入为听书") { confirmImport(preview) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 操作

    private func resolve(bvid raw: String) {
        isResolving = true
        errorMessage = nil
        preview = nil
        Task {
            do {
                let adapter = BiliAdapter()
                var bvid = raw
                // P1-2：先解析输入，处理 b23.tv 短链 / BV号 / av号
                if let parsed = BiliInputParser.parse(raw) {
                    switch parsed {
                    case .shortLink(let url):
                        if let resolved = await adapter.resolveShortLink(url: url),
                           case .video(let resolvedBvid) = resolved {
                            bvid = resolvedBvid
                        } else {
                            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "短链解析失败"])
                        }
                    case .video(let resolvedBvid):
                        bvid = resolvedBvid
                    case .av(let aid):
                        let infoResult = await adapter.videoInfoByAid(aid: aid)
                        if case .success(let info) = infoResult {
                            bvid = info.bvid
                        } else {
                            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "av号解析失败"])
                        }
                    }
                }
                let infoResult = await adapter.videoInfo(bvid: bvid)
                let info = try infoResult.get()
                var titles: [String] = []
                for page in info.pages {
                    titles.append(page.part)
                }
                preview = BiliPreview(
                    title: info.title,
                    upName: info.upName,
                    pageTitles: titles,
                    bvid: bvid,
                    paid: info.paid
                )
            } catch {
                errorMessage = "解析失败：\(error.localizedDescription)"
            }
            isResolving = false
        }
    }

    private func confirmImport(_ preview: BiliPreview) {
        guard !preview.paid else { return }
        isImporting = true
        Task {
            do {
                let adapter = BiliAdapter()
                let infoResult = await adapter.videoInfo(bvid: preview.bvid)
                let info = try infoResult.get()
                let bookId = try await importBiliBook(info: info, bvid: preview.bvid)
                importedBookId = bookId
            } catch {
                errorMessage = "导入失败：\(error.localizedDescription)"
            }
            isImporting = false
        }
    }

    private func importBiliBook(info: BiliAdapter.BiliVideoInfo, bvid: String) async throws -> Int64 {
        // 取现有最大 ID + 1
        let descriptor = FetchDescriptor<ImportedBookModel>(
            sortBy: [SortDescriptor(\.id, order: .reverse)]
        )
        let maxId = (try? modelContext.fetch(descriptor).first?.id) ?? 0
        let newId = maxId + 1

        let book = ImportedBookModel(
            id: newId,
            title: "\(info.title) · \(info.upName)",
            kind: BiliSource.KIND,
            meta: bvid
        )
        modelContext.insert(book)

        for (idx, page) in info.pages.enumerated() {
            let uri = BiliSource.buildChapterUri(bvid: bvid, cid: page.cid)
            let chapter = ImportedChapterModel(
                bookId: newId,
                chapterIdx: idx,
                title: page.part,
                uri: uri
            )
            modelContext.insert(chapter)
        }

        try modelContext.save()
        return newId
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

private struct BiliPreview: Sendable {
    let title: String
    let upName: String
    let pageTitles: [String]
    let bvid: String
    let paid: Bool
}


