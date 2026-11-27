import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models.dart';
import 'source_registry.dart';
import 'source_router.dart';
import 'storage.dart';
import 'playback_manager.dart';
import 'widgets.dart';

class AlbumScreen extends StatefulWidget {
  const AlbumScreen({super.key, required this.album});

  final AppAlbum album;

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  List<AppChapter> _chapters = [];
  bool _loading = true;
  String? _error;
  bool _reversed = false;
  bool _didPosition = false;
  int? _resumeArrayPosition;
  int _resumeMs = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final router = context.read<SourceRouter>();
    try {
      final chapters = await router.chapters(widget.album);
      if (!mounted) return;
      final history = context.read<LocalStore>().historyFor(widget.album.key);
      var pos = 0;
      if (history != null) {
        for (var i = 0; i < chapters.length; i++) {
          if (chapters[i].index == history.chapterIdx) {
            pos = i;
            _resumeMs = history.positionMs;
            break;
          }
        }
        _resumeArrayPosition = pos;
      }
      setState(() {
        _chapters = chapters;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '章节加载失败：$e';
        _loading = false;
      });
    }
  }

  int? get _listenedBeforePosition {
    final pm = context.watch<PlaybackManager>();
    if (pm.currentAlbum?.key == widget.album.key &&
        pm.currentChapterIdx >= 0 &&
        pm.currentChapterIdx < pm.currentChapters.length) {
      return pm.currentChapterIdx;
    }
    return _resumeArrayPosition;
  }

  List<AppChapter> get _displayed =>
      _reversed ? _chapters.reversed.toList() : _chapters;

  bool _isCurrent(AppChapter chapter) {
    final pm = context.watch<PlaybackManager>();
    if (pm.currentAlbum?.key == widget.album.key &&
        pm.currentChapterIdx >= 0 &&
        pm.currentChapterIdx < pm.currentChapters.length &&
        pm.currentChapters[pm.currentChapterIdx].chapterId == chapter.chapterId) {
      return true;
    }
    if (_resumeArrayPosition != null &&
        _chapters.indexOf(chapter) == _resumeArrayPosition) {
      return true;
    }
    return false;
  }

  bool _isListened(AppChapter chapter) {
    final pos = _listenedBeforePosition;
    if (pos == null || pos <= 0) return false;
    final idx = _chapters.indexOf(chapter);
    return idx >= 0 && idx < pos;
  }

  bool _isActivelyPlaying(AppChapter chapter) {
    final pm = context.watch<PlaybackManager>();
    return pm.isPlaying &&
        pm.currentAlbum?.key == widget.album.key &&
        pm.currentChapterIdx >= 0 &&
        pm.currentChapterIdx < pm.currentChapters.length &&
        pm.currentChapters[pm.currentChapterIdx].chapterId == chapter.chapterId;
  }

  Future<void> _playChapter(AppChapter chapter) async {
    final resumeMs = _resumeArrayPosition != null &&
            _chapters.indexOf(chapter) == _resumeArrayPosition
        ? _resumeMs
        : 0;
    // playQueue.start 是章节列表的 0 基数组下标；chapter.index 是音源原生章号
    // （听友FM/B站/易听书均为 1 基），直接传会整体偏移一章。
    final start = _chapters.indexOf(chapter);
    await context.read<PlaybackManager>().playQueue(
          album: widget.album,
          chapters: _chapters,
          start: start < 0 ? 0 : start,
          startPosMs: resumeMs,
        );
  }

  @override
  Widget build(BuildContext context) {
    final listened = _listenedBeforePosition ?? 0;
    return Scaffold(
      appBar: AppBar(title: Text(widget.album.title)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CoverImage(url: widget.album.coverUrl, size: 90),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.album.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (widget.album.author != null) ...[
                        const SizedBox(height: 4),
                        Text(widget.album.author!,
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                      if (widget.album.teller != null) ...[
                        const SizedBox(height: 2),
                        Text('播音：${widget.album.teller}',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          SourceRegistry.displayName(widget.album.source),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_resumeArrayPosition != null &&
              _resumeArrayPosition! < _chapters.length)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: FilledButton.tonalIcon(
                key: const ValueKey('album_resume_button'),
                onPressed: () =>
                    _playChapter(_chapters[_resumeArrayPosition!]),
                icon: const Icon(Icons.play_circle_fill),
                label: Text(
                  '继续收听：${_chapters[_resumeArrayPosition!].title} · 已播 ${_resumePercent()}%',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          if (widget.album.intro != null && widget.album.intro!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                widget.album.intro!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Text(
                  '目录（${_chapters.length} 章）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(width: 8),
                if (listened > 0)
                  Text(
                    '已听 ${listened.clamp(0, _chapters.length).toInt()}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                const Spacer(),
                TextButton.icon(
                  key: const ValueKey('album_chapter_order_toggle'),
                  onPressed: () => setState(() => _reversed = !_reversed),
                  icon: Icon(_reversed ? Icons.arrow_downward : Icons.arrow_upward,
                      size: 16),
                  label: Text(_reversed ? '倒序' : '正序'),
                ),
              ],
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12)),
            )
          else
            for (final chapter in _displayed)
              ListTile(
                key: ValueKey('album_chapter_row_${chapter.index}'),
                dense: true,
                selected: _isCurrent(chapter),
                leading: SizedBox(
                  width: 30,
                  child: chapterTitleHasOwnIndex(chapter.title)
                      ? const Icon(Icons.circle, size: 5)
                      : Text('${chapter.index}.',
                          style: Theme.of(context).textTheme.bodySmall),
                ),
                title: Text(
                  chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _isListened(chapter) && !_isCurrent(chapter)
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : null,
                  ),
                ),
                subtitle: chapter.durationSec == null
                    ? null
                    : Text(formatDuration(chapter.durationSec!)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isActivelyPlaying(chapter))
                      Icon(Icons.volume_up,
                          size: 16, color: Theme.of(context).colorScheme.primary),
                    if (_isListened(chapter) && !_isCurrent(chapter))
                      Icon(Icons.check,
                          key: ValueKey('album_chapter_done_${chapter.index}'),
                          size: 16,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ],
                ),
                onTap: () => _playChapter(chapter),
              ),
        ],
      ),
    );
  }

  int _resumePercent() {
    final pos = _resumeArrayPosition;
    if (pos == null || pos >= _chapters.length) return 0;
    final duration = _chapters[pos].durationSec;
    if (duration == null || duration <= 0) return 0;
    final p = (_resumeMs ~/ 1000 * 100) ~/ duration;
    return p.clamp(0, 100).toInt();
  }
}
