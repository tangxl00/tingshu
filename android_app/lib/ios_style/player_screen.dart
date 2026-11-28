import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'playback_manager.dart';
import 'storage.dart';
import 'widgets.dart';

class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pm = context.watch<PlaybackManager>();
    final store = context.watch<LocalStore>();
    final album = pm.currentAlbum;
    final maxMs = pm.durationMs > 0 ? pm.durationMs.toDouble() : 1.0;
    final pos = pm.positionMs.clamp(0, pm.durationMs).toDouble();

    return Scaffold(
      appBar: AppBar(
        title: const Text(''),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
      body: SafeArea(
        // 播放器页面调整：一页完整展示、不滚动。用 LayoutBuilder 取可用高度，
        // 封面按剩余空间自适应，保证小屏也不溢出。
        child: LayoutBuilder(
          builder: (context, constraints) {
            // v2.0.0：封面缩小到原先的 3/4（240→180）
            final coverSize = ((constraints.maxHeight - 300) * 0.75).clamp(68.0, 180.0).toDouble();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(
                // v2.0.0：整体布局上移，进度条落在屏幕中间偏下
                mainAxisAlignment: MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
              CoverImage(url: pm.coverUrl, size: coverSize, radius: 16),
              const SizedBox(height: 12),
              Text(
                pm.currentAlbumTitle,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                pm.currentChapterTitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // v2.0.0：弹性留白把进度条推到中间偏下（3:1 分配）
              const Spacer(flex: 3),
              if (pm.playbackError != null) ...[
                const SizedBox(height: 12),
                Text(
                  pm.playbackError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error, fontSize: 12),
                ),
                TextButton(
                  key: const ValueKey('player_retry'),
                  onPressed: pm.retryCurrentChapter,
                  child: const Text('重试'),
                ),
              ],
              if (pm.isChapterLoading && pm.playbackError == null) ...[
                const SizedBox(height: 8),
                const Text('加载中…', style: TextStyle(fontSize: 12)),
              ],
              const SizedBox(height: 12),
              Slider(
                key: const ValueKey('player_progress'),
                value: pos,
                max: maxMs,
                onChanged: pm.durationMs > 0
                    ? (v) => pm.seek(v.toInt())
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(formatMs(pm.positionMs),
                        style: const TextStyle(fontFeatures: [ui.FontFeature.tabularFigures()])),
                    Text(formatMs(pm.durationMs),
                        style: const TextStyle(fontFeatures: [ui.FontFeature.tabularFigures()])),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    onPressed: pm.previousChapter,
                    icon: const Icon(Icons.skip_previous, size: 30),
                  ),
                  IconButton(
                    key: const ValueKey('player_play_pause'),
                    tooltip: pm.isPlaying ? '暂停' : '播放',
                    onPressed: pm.togglePlayPause,
                    icon: Icon(
                      pm.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                      size: 64,
                    ),
                  ),
                  IconButton(
                    onPressed: pm.nextChapter,
                    icon: const Icon(Icons.skip_next, size: 30),
                  ),
                ],
              ),
              // 播放器页面调整：删除 ±15 秒跳转与独立倍速行，功能统一收到底部一行。
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _action(
                    context,
                    Icons.list,
                    '章节',
                    () => _showChapters(context),
                  ),
                  _action(
                    context,
                    Icons.bedtime,
                    '定时',
                    () => _showSleepTimer(context),
                  ),
                  _action(
                    context,
                    store.isFavorite(album?.key ?? '') ? Icons.favorite : Icons.favorite_border,
                    '收藏',
                    pm.toggleFavorite,
                  ),
                  // 播放器页面调整：倍速下移，与章节/定时置于同一行（第 4 位）
                  _speedAction(context, pm),
                  _action(
                    context,
                    Icons.settings,
                    '设置',
                    () => _showSettings(context),
                  ),
                ],
              ),
              const Spacer(flex: 1),
            ],
          ),
        );
          },
        ),
      ),
    );
  }

  Widget _action(BuildContext context, IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  /// 倍速入口：与章节/定时同排，图标位显示当前倍速值，便于直接识别。
  Widget _speedAction(BuildContext context, PlaybackManager pm) {
    return InkWell(
      onTap: () => _showSpeedSheet(context),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          children: [
            SizedBox(
              height: 22,
              child: Text('${pm.speed.toStringAsFixed(1)}x',
                  style: const TextStyle(fontSize: 13)),
            ),
            const SizedBox(height: 2),
            const Text('倍速', style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  void _showSpeedSheet(BuildContext context) {
    final pm = context.read<PlaybackManager>();
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('播放倍速')),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              children: [0.75, 1.0, 1.25, 1.5, 2.0, 3.0].map((s) {
                return ChoiceChip(
                  label: Text('${s.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(r'\.$', '')}x'),
                  selected: (pm.speed - s).abs() < 0.01,
                  onSelected: (_) {
                    pm.setSpeed(s);
                    Navigator.of(sheetContext).pop();
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showChapters(BuildContext context) {
    final pm = context.read<PlaybackManager>();
    // 播放器章节面板对齐发现页书籍章节列表：标题+时长两行、已听 ✓、当前章音量标志，
    // 并让当前播放章落在视口中央（上下都有章节）。dense ListTile 带 subtitle 行高 72。
    const double rowHeight = 72;
    final current = pm.currentChapterIdx;
    final controller = ScrollController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        // 布局完成后按视口高度计算居中偏移，避免用 initialScrollOffset 把当前章顶到第一行。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!controller.hasClients) return;
          final viewport = controller.position.viewportDimension;
          final target = current * rowHeight - (viewport - rowHeight) / 2;
          controller.jumpTo(
            target.clamp(0.0, controller.position.maxScrollExtent).toDouble(),
          );
        });
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.7,
            child: Column(
              children: [
                const ListTile(title: Text('章节')),
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    itemExtent: rowHeight,
                    itemCount: pm.currentChapters.length,
                    itemBuilder: (_, i) {
                      final c = pm.currentChapters[i];
                      final isCurrent = i == current;
                      final isListened = i < current;
                      return ListTile(
                        dense: true,
                        selected: isCurrent,
                        leading: Text('${c.index}.'),
                        title: Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isCurrent
                                ? Theme.of(sheetContext).colorScheme.primary
                                : (isListened
                                    ? Theme.of(sheetContext)
                                        .colorScheme
                                        .onSurfaceVariant
                                    : null),
                          ),
                        ),
                        subtitle: c.durationSec == null
                            ? null
                            : Text(formatDuration(c.durationSec!)),
                        trailing: isCurrent
                            ? Icon(Icons.volume_up,
                                size: 18,
                                color: Theme.of(sheetContext).colorScheme.primary)
                            : (isListened
                                ? Icon(Icons.check,
                                    size: 16,
                                    color: Theme.of(sheetContext)
                                        .colorScheme
                                        .onSurfaceVariant)
                                : null),
                        onTap: () {
                          pm.playChapterAt(i);
                          Navigator.of(sheetContext).pop();
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(controller.dispose);
  }

  void _showSleepTimer(BuildContext context) {
    final pm = context.read<PlaybackManager>();
    final modes = [
      (SleepMode.off, '关闭'),
      (SleepMode.chapterEnd, '本章结束'),
      (SleepMode.minutes15, '15 分钟'),
      (SleepMode.minutes30, '30 分钟'),
      (SleepMode.minutes45, '45 分钟'),
      (SleepMode.minutes60, '60 分钟'),
    ];
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('睡眠定时')),
            for (final entry in modes)
              ListTile(
                title: Text(entry.$2),
                trailing: pm.sleepConfig.mode == entry.$1
                    ? const Icon(Icons.check)
                    : null,
                onTap: () {
                  pm.applySleepTimer(SleepConfig(mode: entry.$1));
                  Navigator.of(sheetContext).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showSettings(BuildContext context) {
    final pm = context.read<PlaybackManager>();
    var intro = pm.skipIntro.toDouble();
    var outro = pm.skipOutro.toDouble();
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (builderContext, setState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('片头跳过：${intro.toInt()} 秒'),
                Slider(
                  value: intro,
                  max: 300,
                  divisions: 30,
                  onChanged: (v) => setState(() => intro = v),
                ),
                Text('片尾跳过：${outro.toInt()} 秒'),
                Slider(
                  value: outro,
                  max: 300,
                  divisions: 30,
                  onChanged: (v) => setState(() => outro = v),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () {
                    pm.setIntroSkip(intro.toInt());
                    pm.setOutroSkip(outro.toInt());
                    Navigator.of(sheetContext).pop();
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

