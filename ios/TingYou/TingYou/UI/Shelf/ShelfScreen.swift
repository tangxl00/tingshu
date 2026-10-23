import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ShelfScreen: View {
    @Query(sort: \FavoriteModel.createdAt, order: .reverse) private var favorites: [FavoriteModel]
    @Query(sort: \HistoryModel.updatedAt, order: .reverse) private var histories: [HistoryModel]
    @Query(sort: \ImportedBookModel.createdAt, order: .reverse) private var importedBooks: [ImportedBookModel]
    @State private var layout: Int = 0
    @State private var selectedTab = 0
    @State private var showClearConfirm = false
    @State private var showOnlineImport = false
    @State private var showNetDiskInfo = false
    @State private var onlineText = ""
    @State private var showDocumentPicker = false
    @State private var importMessage: String?
    @State private var showImportMessage = false
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var modelContext

    let onOpenPlayer: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab + More menu
                HStack(spacing: 0) {
                    Picker("", selection: $selectedTab) {
                        Text("收藏 (\(favorites.count))").tag(0)
                        Text("历史 (\(histories.count))").tag(1)
                        Text("导入 (\(importedBooks.count))").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)

                    Menu {
                        Section("书籍排列") {
                            Button(action: { layout = 0 }) {
                                Label("列表", systemImage: layout == 0 ? "checkmark" : "list.bullet")
                            }
                            Button(action: { layout = 1 }) {
                                Label("九宫格", systemImage: layout == 1 ? "checkmark" : "square.grid.2x2")
                            }
                        }
                        Section("外部导入") {
                            Button(action: { showDocumentPicker = true }) {
                                Label("本地导入", systemImage: "folder")
                            }
                            Button(action: { showOnlineImport = true }) {
                                Label("网页导入", systemImage: "link")
                            }
                            Button(action: { showNetDiskInfo = true }) {
                                Label("网盘解析", systemImage: "cloud")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Content
                if selectedTab == 0 {
                    favoritesContent
                } else if selectedTab == 1 {
                    historyContent
                } else {
                    importedContent
                }
            }
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.large)
            .alert("清空播放历史", isPresented: $showClearConfirm) {
                Button("清空", role: .destructive) { clearAllHistory() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("将删除全部 \(histories.count) 条播放记录，且无法恢复。确定吗？")
            }
            .sheet(isPresented: $showOnlineImport) {
                OnlineImportSheet(
                    text: $onlineText,
                    onConfirm: {
                        parseOnlineImport(onlineText)
                        showOnlineImport = false
                    },
                    onDismiss: { showOnlineImport = false }
                )
            }
            .alert("网盘解析暂不可用", isPresented: $showNetDiskInfo) {
                Button("知道了") { }
            } message: {
                Text("百度、夸克、阿里等网盘的音频分享链接解析需登录态或开放平台凭据，App 端在未提供凭据前无法稳定获取直链；为避免引入 trust-all 等安全风险，本版本暂不提供该入口的实功能。")
            }
            .alert("导入", isPresented: $showImportMessage) {
                Button("知道了") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
            .fileImporter(
                isPresented: $showDocumentPicker,
                allowedContentTypes: [UTType.audio, UTType.mpeg4Audio, UTType.mp3],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    processLocalImport(urls: urls)
                case .failure(let error):
                    importMessage = "选择文件失败: \(error.localizedDescription)"
                    showImportMessage = true
                }
            }
        }
    }

    /// build 28 · 按 (src, albumId) 查找最近一条播放历史，用于收藏卡片进度展示。
    private func historyForFavorite(_ f: FavoriteModel) -> HistoryModel? {
        histories.first { $0.src == f.src && $0.albumId == f.albumId }
    }

    @ViewBuilder
    private var favoritesContent: some View {
        if favorites.isEmpty {
            ContentUnavailableView("还没有收藏", systemImage: "books.vertical", description: Text("在发现页浏览并收藏书籍"))
        } else if layout == 0 {
            List {
                ForEach(favorites) { f in
                    NavigationLink {
                        AlbumScreen(album: Album(
                            albumId: f.albumId, title: f.title, author: f.author,
                            teller: f.teller, coverUrl: f.coverUrl, intro: nil,
                            category: nil, categoryId: nil, type: nil, typeId: nil,
                            status: f.status, chapterCount: f.chapterCount,
                            updatedAt: nil, playCount: nil, available: true,
                            source: f.src, detailPath: f.detailPath
                        ))
                    } label: {
                        FavoriteRow(favorite: f, history: historyForFavorite(f))
                    }
                }
                .onDelete(perform: deleteFavorites)
            }
            .listStyle(.plain)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                    ForEach(favorites) { f in
                        NavigationLink {
                            AlbumScreen(album: Album(
                                albumId: f.albumId, title: f.title, author: f.author,
                                teller: f.teller, coverUrl: f.coverUrl, intro: nil,
                                category: nil, categoryId: nil, type: nil, typeId: nil,
                                status: f.status, chapterCount: f.chapterCount,
                                updatedAt: nil, playCount: nil, available: true,
                                source: f.src, detailPath: f.detailPath
                            ))
                        } label: {
                            FavoriteGridItem(favorite: f, history: historyForFavorite(f))
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if histories.isEmpty {
            ContentUnavailableView("暂无播放历史", systemImage: "clock", description: Text("开始收听吧"))
        } else {
            HStack {
                Spacer()
                Button(action: { showClearConfirm = true }) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing)
            }
            if layout == 0 {
                List {
                    ForEach(histories) { h in
                        Button {
                            resumeHistory(h)
                        } label: {
                            HistoryRow(history: h)
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete(perform: deleteHistories)
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                        ForEach(histories) { h in
                            Button {
                                resumeHistory(h)
                            } label: {
                                HistoryGridItem(history: h)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    /// P0-4：导入书籍列表（B站 / 59听书网）
    @ViewBuilder
    private var importedContent: some View {
        if importedBooks.isEmpty {
            ContentUnavailableView("暂无导入书籍", systemImage: "arrow.down.circle", description: Text("在发现页导入B站或59听书网书籍"))
        } else if layout == 0 {
            List {
                ForEach(importedBooks) { book in
                    NavigationLink {
                        AlbumScreen(album: albumFromImported(book))
                    } label: {
                        ImportedBookRow(book: book)
                    }
                }
                .onDelete(perform: deleteImportedBooks)
            }
            .listStyle(.plain)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                    ForEach(importedBooks) { book in
                        NavigationLink {
                            AlbumScreen(album: albumFromImported(book))
                        } label: {
                            ImportedBookGridItem(book: book)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// 从 ImportedBookModel 构造 Album（供导入 Tab 与导航使用）
    private func albumFromImported(_ book: ImportedBookModel) -> Album {
        let src: String
        let detailPath: String?
        switch book.kind {
        case BiliSource.KIND:
            src = BiliSource.SRC
            detailPath = book.meta
        case Ting59Source.KIND:
            src = Ting59Source.SRC
            detailPath = book.meta.map { "/mp3/\($0).html" }
        default:
            src = book.kind
            detailPath = book.meta
        }
        return Album(
            albumId: book.id, title: book.title, author: nil, teller: nil,
            coverUrl: nil, intro: nil, category: nil, categoryId: nil,
            type: nil, typeId: nil, status: nil, chapterCount: nil,
            updatedAt: nil, playCount: nil, available: true,
            source: src, detailPath: detailPath
        )
    }

    private func deleteImportedBooks(at offsets: IndexSet) {
        for idx in offsets {
            modelContext.delete(importedBooks[idx])
        }
        do { try modelContext.save() } catch { print("deleteImportedBooks save failed: \(error)") }
    }

    /// build 20 必修 2：书架恢复播放重建完整章节队列。
    /// 旧实现传 chapters: [chapter] 单章数组，恢复后上/下一章失效（播放队列只有一章）。
    /// 现改为：用历史里的 src/albumId/detailPath 拉取完整章节列表后入队；
    /// 拉取失败降级为旧的单章行为并打日志（不打断恢复）。
    private func resumeHistory(_ h: HistoryModel) {
        let album = Album(
            albumId: h.albumId, title: h.albumTitle, author: nil, teller: nil,
            coverUrl: h.coverUrl, intro: nil, category: nil, categoryId: nil,
            type: nil, typeId: nil, status: nil, chapterCount: nil,
            updatedAt: nil, playCount: nil, available: true,
            source: h.src, detailPath: h.detailPath
        )
        let router = container?.sourceRouter
        let planner = HistoryResumePlanner(fetchChapters: { src, albumId, detailPath in
            guard let router else { throw HistoryResumePlanner.FetchUnavailableError() }
            return try await router.chapters(src: src, albumId: albumId, detailPath: detailPath)
        })
        Task { @MainActor in
            let outcome = await planner.plan(
                src: h.src, albumId: h.albumId, detailPath: h.detailPath,
                chapterIdx: h.chapterIdx, chapterTitle: h.chapterTitle
            )
            switch outcome {
            case .fullQueue(let chapters, let startIdx):
                container?.playbackManager.playQueue(
                    album: album, chapters: chapters, startIdx: startIdx, startPosMs: h.positionMs
                )
            case .singleChapter(let chapter):
                container?.playbackManager.playQueue(
                    album: album, chapters: [chapter], startIdx: h.chapterIdx, startPosMs: h.positionMs
                )
            }
            onOpenPlayer()
        }
    }

    private func deleteFavorites(at offsets: IndexSet) {
        for idx in offsets {
            modelContext.delete(favorites[idx])
        }
        // build 20 自查：删除收藏的落库不允许静默吞错（与 P1-1 修法一致）
        do { try modelContext.save() } catch { print("deleteFavorites save failed: \(error)") }
    }

    private func deleteHistories(at offsets: IndexSet) {
        for idx in offsets {
            modelContext.delete(histories[idx])
        }
        // build 20 自查：删除历史的落库不允许静默吞错
        do { try modelContext.save() } catch { print("deleteHistories save failed: \(error)") }
    }

    private func clearAllHistory() {
        for h in histories {
            modelContext.delete(h)
        }
        // build 20 自查：清空历史的落库不允许静默吞错
        do { try modelContext.save() } catch { print("clearAllHistory save failed: \(error)") }
    }

    // MARK: - Local Import
    private func processLocalImport(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let names = urls.map { $0.lastPathComponent }
        let sorted = names.enumerated().sorted {
            ImportOrganizer.naturalCompare($0.element, $1.element) < 0
        }
        let sortedNames = sorted.map { $0.element }
        let sortedUrls = sorted.map { urls[$0.offset] }
        let title = ImportOrganizer.suggestBookTitle(sortedNames)
        let links = sortedNames.enumerated().map { (idx, name) in
            ImportOrganizer.ImportLink(url: sortedUrls[idx].absoluteString, title: ImportOrganizer.chapterTitle(name))
        }
        Task {
            do {
                let _ = try await container?.importService.importLinks(
                    title: title,
                    links: links.map { ($0.url, $0.title) }
                )
                importMessage = "已导入《\(title)》（\(links.count) 集）"
                showImportMessage = true
            } catch {
                importMessage = "导入失败: \(error.localizedDescription)"
                showImportMessage = true
            }
        }
    }

    // MARK: - Online Import
    private func parseOnlineImport(_ text: String) {
        let result = ImportOrganizer.parseDirectLinks(text)
        if let bad = result.badLines, !bad.isEmpty {
            importMessage = "已拒绝非 https 链接：\(bad.prefix(2).joined(separator: "；"))"
            showImportMessage = true
            return
        }
        guard let links = result.links, !links.isEmpty else {
            importMessage = "未解析到有效链接"
            showImportMessage = true
            return
        }
        let title = ImportOrganizer.suggestBookTitle(links.map { $0.title ?? $0.url })
        Task {
            do {
                let _ = try await container?.importService.importLinks(
                    title: title,
                    links: links.map { ($0.url, $0.title) }
                )
                importMessage = "已导入《\(title)》（\(links.count) 条链接）"
                showImportMessage = true
            } catch {
                importMessage = "导入失败: \(error.localizedDescription)"
                showImportMessage = true
            }
        }
    }
}

// MARK: - Import Sheet

struct OnlineImportSheet: View {
    @Binding var text: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("一行一条 https 直链（可多行）。也支持一条 .m3u / .m3u8 播放列表链接。仅接受 https（App 禁明文流量）；不支持网盘分享页。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle("在线导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解析", action: onConfirm)
                        .disabled(text.isEmpty)
                }
            }
        }
    }
}

struct HistoryRow: View {
    let history: HistoryModel
    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: history.coverUrl, size: 60, source: history.src)
            VStack(alignment: .leading, spacing: 4) {
                Text(history.albumTitle).lineLimit(1).font(.subheadline)
                Text("\(history.chapterTitle)").lineLimit(1).font(.caption).foregroundStyle(.secondary)
                Text(progressText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    var progressText: String {
        let pct = history.durationMs > 0 ? Int(Double(history.positionMs) / Double(history.durationMs) * 100) : 0
        return "已播 \(pct)%"
    }
}

struct HistoryGridItem: View {
    let history: HistoryModel
    var body: some View {
        VStack(spacing: 4) {
            CoverImage(url: history.coverUrl, size: 100, source: history.src)
            Text(history.albumTitle).lineLimit(1).font(.caption)
            Text("\(history.chapterTitle)").lineLimit(1).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct FavoriteRow: View {
    let favorite: FavoriteModel
    /// build 28 · 关联的播放历史（按 src+albumId 匹配），nil 表示未听过。
    let history: HistoryModel?

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: favorite.coverUrl, size: 60, source: favorite.src)
            VStack(alignment: .leading, spacing: 4) {
                Text(favorite.title).lineLimit(1).font(.subheadline)
                if let author = favorite.author {
                    Text(author).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
                // build 28 · 收藏进度：对齐 HistoryRow caption 风格
                Text(progressCaption).lineLimit(1).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var progressCaption: String {
        guard let h = history else { return "未开始" }
        let pct = h.durationMs > 0 ? Int(Double(h.positionMs) / Double(h.durationMs) * 100) : 0
        return "\(h.chapterTitle) · 已播 \(pct)%"
    }
}

struct FavoriteGridItem: View {
    let favorite: FavoriteModel
    /// build 28 · 关联的播放历史（按 src+albumId 匹配），nil 表示未听过。
    let history: HistoryModel?

    var body: some View {
        VStack(spacing: 4) {
            CoverImage(url: favorite.coverUrl, size: 100, source: favorite.src)
            Text(favorite.title).lineLimit(1).font(.caption)
            // build 28 · 收藏进度：网格中简化为百分比或「未开始」
            Text(progressCaption).lineLimit(1).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var progressCaption: String {
        guard let h = history else { return "未开始" }
        let pct = h.durationMs > 0 ? Int(Double(h.positionMs) / Double(h.durationMs) * 100) : 0
        return "已播 \(pct)%"
    }
}

// MARK: - Imported Book Views

struct ImportedBookRow: View {
    let book: ImportedBookModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).lineLimit(1).font(.subheadline)
                Text(kindLabel).lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var kindLabel: String {
        switch book.kind {
        case BiliSource.KIND: return "B站"
        case Ting59Source.KIND: return "59听书网"
        default: return book.kind
        }
    }
}

struct ImportedBookGridItem: View {
    let book: ImportedBookModel

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.down.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .foregroundStyle(.secondary)
            Text(book.title).lineLimit(1).font(.caption)
            Text(kindLabel).lineLimit(1).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var kindLabel: String {
        switch book.kind {
        case BiliSource.KIND: return "B站"
        case Ting59Source.KIND: return "59听书网"
        default: return book.kind
        }
    }
}
