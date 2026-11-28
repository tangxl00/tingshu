import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'album_screen.dart';
import 'import_organizer.dart';
import 'models.dart';
import 'playback_manager.dart';
import 'source_registry.dart';
import 'source_router.dart';
import 'storage.dart';
import 'widgets.dart';

class ShelfScreen extends StatefulWidget {
  const ShelfScreen({super.key, required this.onOpenPlayer});

  final VoidCallback onOpenPlayer;

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  int _tab = 0;
  int _layout = 0;
  final TextEditingController _importController = TextEditingController();

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  void _openAlbum(AppAlbum album) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AlbumScreen(album: album)),
    );
  }

  Future<void> _resumeHistory(HistoryRecord history) async {
    final router = context.read<SourceRouter>();
    try {
      final chapters = await router.chapters(history.toAlbum());
      if (chapters.isEmpty) return;
      var pos = 0;
      for (var i = 0; i < chapters.length; i++) {
        if (chapters[i].index == history.chapterIdx) {
          pos = i;
          break;
        }
      }
      await context.read<PlaybackManager>().playQueue(
            album: history.toAlbum(),
            chapters: chapters,
            start: pos,
            startPosMs: history.positionMs,
          );
      widget.onOpenPlayer();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复播放失败：$e')),
      );
    }
  }

  Future<void> _pickLocalFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.audio,
      );
      if (result == null || result.files.isEmpty) return;
      final files = result.files
          .where((f) => f.path != null && f.path!.isNotEmpty)
          .toList();
      if (files.isEmpty) return;
      final names = files.map((f) => f.name).toList();
      final sorted = names.asMap().entries.toList()
        ..sort((a, b) => naturalCompare(a.value, b.value));
      final title = suggestBookTitle(sorted.map((e) => e.value).toList());
      final links = sorted
          .map((e) => (
                uri: files[e.key].path!,
                title: chapterTitle(e.value),
              ))
          .toList();
      await context.read<LocalStore>().importLinks(title, links);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入《$title》（${links.length} 集）')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  Future<void> _parseOnlineImport() async {
    final result = parseDirectLinks(_importController.text);
    if (result.badLines.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('已拒绝非 https 链接：${result.badLines.first}')),
      );
      return;
    }
    if (result.links.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未解析到有效链接')));
      return;
    }
    final title = suggestBookTitle(
        result.links.map((l) => l.title ?? l.url).toList());
    await context.read<LocalStore>().importLinks(
          title,
          result.links
              .map((l) => (uri: l.url, title: l.title ?? chapterTitle(l.url)))
              .toList(),
        );
    _importController.clear();
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导入《$title》（${result.links.length} 条）')),
    );
  }

  void _showOnlineImport() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('在线导入', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '一行一条 https 直链（可多行）。也支持一条 .m3u8 播放列表链接。仅接受 https；不支持网盘分享页。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _importController,
              maxLines: 6,
              decoration: const InputDecoration(
                hintText: 'https://example.com/01.mp3',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: _parseOnlineImport,
                  child: const Text('解析'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showImportedBooks() {
    final store = context.read<LocalStore>();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.65,
          child: Column(
            children: [
              const ListTile(title: Text('导入书籍')),
              Expanded(
                child: store.importedBooks.isEmpty
                    ? const EmptyView(icon: Icons.folder_open, title: '暂无导入书籍')
                    : ListView.builder(
                        itemCount: store.importedBooks.length,
                        itemBuilder: (_, i) {
                          final book = store.importedBooks[i];
                          return ListTile(
                            title: Text(book.title),
                            subtitle: Text('${book.chapters.length} 集'),
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              _openAlbum(book.toAlbum());
                            },
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () =>
                                  store.deleteImportedBook(book.id),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LocalStore>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'list':
                  setState(() => _layout = 0);
                  break;
                case 'grid':
                  setState(() => _layout = 1);
                  break;
                case 'local':
                  _pickLocalFiles();
                  break;
                case 'online':
                  _showOnlineImport();
                  break;
                case 'imported':
                  _showImportedBooks();
                  break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'list', child: Text('列表')),
              const PopupMenuItem(value: 'grid', child: Text('九宫格')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'local', child: Text('本地导入')),
              const PopupMenuItem(value: 'online', child: Text('在线导入')),
              const PopupMenuItem(value: 'imported', child: Text('导入书籍')),
            ],
            icon: const Icon(Icons.more_horiz),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<int>(
                    segments: [
                      ButtonSegment(
                          value: 0,
                          label: Text('收藏 (${store.favorites.length})')),
                      ButtonSegment(
                          value: 1,
                          label: Text('历史 (${store.histories.length})')),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (s) => setState(() => _tab = s.first),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _tab == 0 ? _favorites(store) : _histories(store),
          ),
        ],
      ),
    );
  }

  Widget _favorites(LocalStore store) {
    if (store.favorites.isEmpty) {
      return const EmptyView(
        icon: Icons.menu_book,
        title: '还没有收藏',
        message: '在发现页浏览并收藏书籍',
      );
    }
    if (_layout == 1) {
      return GridView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 120,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: store.favorites.length,
        itemBuilder: (context, i) {
          final f = store.favorites[i];
          final history = store.historyFor(f.key);
          return GestureDetector(
            onTap: () => _openAlbum(f.toAlbum()),
            child: Column(
              children: [
                CoverImage(url: f.coverUrl, size: 100),
                const SizedBox(height: 4),
                Text(f.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  history == null ? '未开始' : history.chapterProgressText,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          );
        },
      );
    }
    return ListView.builder(
      itemCount: store.favorites.length,
      itemBuilder: (context, i) {
        final f = store.favorites[i];
        final history = store.historyFor(f.key);
        return Dismissible(
          key: ValueKey(f.key),
          background: Container(color: Colors.red),
          onDismissed: (_) => store.removeFavorite(f.key),
          child: ListTile(
            key: ValueKey('favorite_row_$i'),
            leading: CoverImage(url: f.coverUrl, size: 56),
            title: Text(f.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              history == null
                  ? '未开始'
                  : '${history.chapterProgressText} · 已播 ${history.percent}%',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _openAlbum(f.toAlbum()),
          ),
        );
      },
    );
  }

  Widget _histories(LocalStore store) {
    if (store.histories.isEmpty) {
      return const EmptyView(
        icon: Icons.history,
        title: '暂无播放历史',
        message: '开始收听吧',
      );
    }
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('清空播放历史'),
                  content: Text('将删除全部 ${store.histories.length} 条播放记录，且无法恢复。确定吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () {
                        store.clearHistories();
                        Navigator.of(dialogContext).pop();
                      },
                      child: const Text('清空'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: store.histories.length,
            itemBuilder: (context, i) {
              final h = store.histories[i];
              return Dismissible(
                key: ValueKey('${h.key}-${h.updatedAt}'),
                background: Container(color: Colors.red),
                onDismissed: (_) => store.deleteHistory(h.key),
                child: ListTile(
                  leading: CoverImage(url: h.coverUrl, size: 56),
                  title: Text(h.albumTitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${h.chapterProgressText} · 已播 ${h.percent}%',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => _resumeHistory(h),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
