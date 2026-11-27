import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'playback_manager.dart';

String formatMs(int ms) {
  final sec = ms ~/ 1000;
  final m = sec ~/ 60;
  final s = sec % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String formatDuration(int seconds) {
  return formatMs(seconds * 1000);
}

String formatListeningTime(int ms) {
  final sec = ms ~/ 1000;
  final h = sec ~/ 3600;
  final m = (sec % 3600) ~/ 60;
  if (h > 0) return '$h小时$m分';
  return '$m分钟';
}

class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.size = 60,
    this.radius = 8,
  });

  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(Icons.auto_stories, size: size * 0.42),
    );
    final value = url;
    if (value == null || value.isEmpty) return placeholder;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      return placeholder;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: value,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.icon, required this.title, this.message});

  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pm = context.watch<PlaybackManager>();
    if (!pm.hasMedia) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          elevation: 4,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  CoverImage(url: pm.coverUrl, size: 40, radius: 7),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          pm.currentAlbumTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          pm.currentChapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('mini_play_pause'),
                    tooltip: pm.isPlaying ? '暂停' : '播放',
                    icon: Icon(pm.isPlaying ? Icons.pause : Icons.play_arrow),
                    onPressed: () => pm.togglePlayPause(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
