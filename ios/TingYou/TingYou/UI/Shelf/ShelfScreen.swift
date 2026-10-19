import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ShelfScreen: View {
    @Query(sort: \FavoriteModel.createdAt, order: .reverse) private var favorites: [FavoriteModel]
    @Query(sort: \HistoryModel.updatedAt, order: .reverse) private var histories: [HistoryModel]
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
                } else {
                    historyContent
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
                        FavoriteRow(favorite: f)
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
                            FavoriteGridItem(favorite: f)
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

    private func resumeHistory(_ h: HistoryModel) {
        // Build a minimal album and chapters to resume playback
        let album = Album(
            albumId: h.albumId, title: h.albumTitle, author: nil, teller: nil,
            coverUrl: h.coverUrl, intro: nil, category: nil, categoryId: nil,
            type: nil, typeId: nil, status: nil, chapterCount: nil,
            updatedAt: nil, playCount: nil, available: true,
            source: h.src, detailPath: h.detailPath
        )
        let chapter = Chapter(
            chapterId: Int64(h.chapterIdx), index: h.chapterIdx,
            title: h.chapterTitle, durationSec: nil
        )
        container?.playbackManager.playQueue(
            album: album, chapters: [chapter], startIdx: h.chapterIdx, startPosMs: h.positionMs
        )
        onOpenPlayer()
    }

    private func deleteFavorites(at offsets: IndexSet) {
        for idx in offsets {
            modelContext.delete(favorites[idx])
        }
        try? modelContext.save()
    }

    private func deleteHistories(at offsets: IndexSet) {
        for idx in offsets {
            modelContext.delete(histories[idx])
        }
        try? modelContext.save()
    }

    private func clearAllHistory() {
        for h in histories {
            modelContext.delete(h)
        }
        try? modelContext.save()
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
            CoverImage(url: history.coverUrl, size: 60)
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
            CoverImage(url: history.coverUrl, size: 100)
            Text(history.albumTitle).lineLimit(1).font(.caption)
            Text("\(history.chapterTitle)").lineLimit(1).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct FavoriteRow: View {
    let favorite: FavoriteModel
    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: favorite.coverUrl, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(favorite.title).lineLimit(1).font(.subheadline)
                if let author = favorite.author {
                    Text(author).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct FavoriteGridItem: View {
    let favorite: FavoriteModel
    var body: some View {
        VStack(spacing: 4) {
            CoverImage(url: favorite.coverUrl, size: 100)
            Text(favorite.title).lineLimit(1).font(.caption)
        }
    }
}
