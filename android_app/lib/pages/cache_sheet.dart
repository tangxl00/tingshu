import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/storage/cache_store.dart';
import '../core/theme/app_theme.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../player/book_player.dart';
import '../services/umeng_analytics.dart';

/// 缓存选集：勾选章节后批量下载，下载完可离线播放
///
/// 两种入口：
/// - 播放页：传入 [book]（当前书）与预选章节
/// - 详情页：同样传入 [book]，章节取自详情数据
class CacheSheet extends StatefulWidget {
  final Book? book;
  final int? preselectIndex;
  const CacheSheet({super.key, this.book, this.preselectIndex});

  static Future<void> show(BuildContext context,
      {Book? book, int? preselectIndex}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      scrollControlDisabledMaxHeightRatio: 0.9,
      showDragHandle: true,
      builder: (_) => CacheSheet(
          book: book, preselectIndex: preselectIndex),
    );
  }

  @override
  State<CacheSheet> createState() => _CacheSheetState();
}

class _CacheSheetState extends State<CacheSheet> {
  final Set<int> _selected = {};
  bool _running = false;
  bool _initDone = false;

  Book? get _book => widget.book ?? context.read<BookPlayer>().book;

  List<Chapter> get _chapters {
    final explicit = widget.book?.chapters;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return context.read<BookPlayer>().chapters;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _initDone = true;
      });
    });
  }

  /// 加入后台缓存队列：立刻返回，下载在后台继续（可离开本页面）
  Future<void> _start() async {
    if (_running || _selected.isEmpty) return;
    final book = _book;
    final chapters = _chapters;
    if (book == null || chapters.isEmpty) return;

    final player = context.read<BookPlayer>();
    final cache = context.read<CacheStore>();
    final list = _selected.toList()..sort();

    final items =
        <({int cid, String chapterTitle, int durationSec, int page, String part, int order})>[];
    for (final i in list) {
      if (i < 0 || i >= chapters.length) continue;
      final c = chapters[i];
      if (cache.isCached(book.bvid, c.cid)) continue;
      items.add((
        cid: c.cid,
        chapterTitle: '${c.page} · ${c.part}',
        durationSec: c.duration,
        page: c.page,
        part: c.part,
        order: i + 1,
      ));
    }

    final total = list.length;
    final already = total - items.length;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选中的 $total 集都已缓存'), duration: const Duration(seconds: 2)),
      );
      Navigator.of(context).pop();
      return;
    }

    AppAnalytics.onEvent('cache_start', {'count': items.length});

    await cache.enqueue(
      bvid: book.bvid,
      bookTitle: book.cleanTitle,
      cover: book.pic,
      items: items,
      resolveUrl: (bvid, cid) => player.resolveUrlFor(bvid, cid),
      headers: player.downloadHeaders,
    );

    if (!mounted) return;
    setState(() => _running = false);
    final msg = already > 0
        ? '已开始后台缓存 ${items.length} 集（$already 集已缓存）'
        : '已开始后台缓存 ${items.length} 集';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cache = context.watch<CacheStore>();
    final book = _book;
    final chapters = _chapters;

    if (!_initDone || chapters.isEmpty || book == null) {
      return const SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator(color: AppTheme.accent)),
      );
    }

    final bvid = book.bvid;

    final running = _running;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Icon(Icons.download_for_offline_outlined,
                    size: 20, color: AppTheme.accent),
                const SizedBox(width: 8),
                Text(
                  '缓存选集',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textMain,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: running
                      ? null
                      : () {
                          setState(() {
                            if (_selected.length == chapters.length) {
                              _selected.clear();
                            } else {
                              _selected
                                ..clear()
                                ..addAll(List.generate(chapters.length, (i) => i));
                            }
                          });
                        },
                  child: Text(
                    _selected.length == chapters.length ? '取消全选' : '全选',
                    style: TextStyle(
                      fontSize: 13,
                      color: running ? AppTheme.textHint : AppTheme.accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              '${book.cleanTitle} · 共 ${chapters.length} 集\n'
              '已缓存 ${cache.countOf(bvid)} 集 · 占用 ${cache.totalSizeText}',
              style: TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: chapters.length,
              itemBuilder: (context, i) {
                final c = chapters[i];
                final cached = cache.isCached(bvid, c.cid);
                final task = cache.taskOf(bvid, c.cid);
                final busy = task != null && !task.done && !task.failed;
                return CheckboxListTile(
                  value: _selected.contains(i),
                  onChanged: running
                      ? null
                      : (v) => setState(() {
                            if (v == true) {
                              _selected.add(i);
                            } else {
                              _selected.remove(i);
                            }
                          }),
                  dense: true,
                  title: Text(
                    '${c.page} · ${c.part}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: cached ? AppTheme.textHint : AppTheme.textMain,
                    ),
                  ),
                  subtitle: Text(
                    busy
                        ? '下载中 ${(task.progress * 100).round()}%'
                        : cached
                            ? '已缓存'
                            : c.durationText,
                    style: TextStyle(
                      fontSize: 12,
                      color: busy || cached ? AppTheme.accent : AppTheme.textSub,
                    ),
                  ),
                  secondary: cached && !busy
                      ? Icon(Icons.offline_pin_rounded,
                          size: 20, color: AppTheme.accent)
                      : null,
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (_running || _selected.isEmpty) ? null : _start,
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: Text(
                        running
                            ? '正在后台缓存…'
                            : '缓存选中的 ${_selected.length} 集（后台）',
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '开始后可离开本页，下载会在后台继续，完成后可在「我的 → 离线缓存」查看',
                    style: TextStyle(fontSize: 11, color: AppTheme.textHint),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}