import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/nav/home_tabs.dart';
import '../core/storage/shelf_store.dart';
import '../core/theme/app_theme.dart';
import '../player/book_player.dart';
import '../pages/player_page.dart';

/// 书架进度徽标（百分比）
class ShelfProgressBadge extends StatelessWidget {
  final double percent;
  const ShelfProgressBadge({super.key, required this.percent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.accent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${(percent * 100).round()}%',
        style: const TextStyle(fontSize: 11, color: Colors.white),
      ),
    );
  }
}

/// 空态占位（书架 / 收藏 / 最近收听共用）
class EmptyShelfView extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;

  const EmptyShelfView({
    super.key,
    this.title = '书架还是空的',
    this.subtitle = '去「发现」搜索一本喜欢的书吧',
    this.icon = Icons.library_books_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 72, color: AppTheme.textHint),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSub,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppTheme.textHint),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).maybePop();
              HomeTabs.switchTo(1);
            },
            icon: const Icon(Icons.explore_outlined, size: 18),
            label: const Text('去发现'),
          ),
        ],
      ),
    );
  }
}

/// 书架/我的书架 点击：直接进播放页，加载与兜底都在播放页里完成
///
/// 不在这里先等加载结果再跳转——那样没网或加载慢的时候，用户点一下
/// 会对着书架干等。现在立刻跳转，播放页自己显示进度和错误。
/// 长按仍然走移出书架；要进书籍详情可以在播放页点书名。
Future<void> playFromShelf(BuildContext context, ShelfBook sb) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final player = context.read<BookPlayer>();
  final shelf = context.read<ShelfStore>();
  player.flushProgress();

  // 立刻进播放页
  final route = MaterialPageRoute<void>(builder: (_) => const PlayerPage());
  navigator.push(route);

  final r = await player.playBookWithFallback(sb);
  if (!context.mounted) return;

  switch (r) {
    case ShelfPlayOutcome.ok:
      return;

    case ShelfPlayOutcome.bookGone:
      // 网络是通的但内容没了 → 问用户要不要把这本清掉
      final remove = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text('作品已下架',
              style: TextStyle(color: AppTheme.textMain, fontSize: 17)),
          content: Text(
            '《${sb.book.cleanTitle}》在平台上已无法访问（可能被删除或下架），'
            '本地也没有它的离线缓存。\n\n要把这本书移出书架吗？',
            style: TextStyle(
                color: AppTheme.textSub, fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child:
                  Text('仅关闭', style: TextStyle(color: AppTheme.textSub)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('移出并关闭',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ),
          ],
        ),
      );
      if (!context.mounted) return;
      if (remove == true) {
        await shelf.remove(sb.book.bvid);
        if (!context.mounted) return;
        messenger.showSnackBar(
          SnackBar(content: Text('已将《${sb.book.cleanTitle}》移出书架')),
        );
      }
      // 只在播放页还留在最上层时关它，避免用户已手动关掉后误关别的页面
      if (route.isCurrent) navigator.pop();
      return;
    case ShelfPlayOutcome.loadFailed:
      // 播放页里已经显示了具体原因（无网络/没有离线缓存），
      // 这里只补一条提示，用户可以直接关掉播放页
      messenger.showSnackBar(
        const SnackBar(
          content: Text('加载失败：请检查网络，或先缓存这本书再离线收听'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
  }
}

/// 确认后把书移出书架（收听进度一并清除）
Future<void> confirmRemoveFromShelf(BuildContext context, ShelfBook sb) async {
  final shelf = context.read<ShelfStore>();
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.surface,
      title: Text(
        '移出书架',
        style: TextStyle(color: AppTheme.textMain, fontSize: 17),
      ),
      content: Text(
        '确定将《${sb.book.cleanTitle}》移出书架吗？\n收听进度也会一并清除。',
        style: TextStyle(color: AppTheme.textSub, fontSize: 13, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('取消', style: TextStyle(color: AppTheme.textSub)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text('移出', style: TextStyle(color: AppTheme.accent)),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await shelf.remove(sb.book.bvid);
  messenger.showSnackBar(
    SnackBar(content: Text('已将《${sb.book.cleanTitle}》移出书架')),
  );
}
