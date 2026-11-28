import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/app_meta.dart';
import '../services/app_update.dart';
import '../services/browser.dart';
import 'disclaimer_screen.dart';
import 'source_manage_screen.dart';
import 'storage.dart';
import 'widgets.dart';

class MineScreen extends StatefulWidget {
  const MineScreen({super.key, required this.onOpenShelf});

  final VoidCallback onOpenShelf;

  @override
  State<MineScreen> createState() => _MineScreenState();
}

class _MineScreenState extends State<MineScreen> {
  bool _checking = false;

  Future<void> _checkUpdate(BuildContext context) async {
    if (_checking) return;
    setState(() => _checking = true);
    final result = await AppUpdate.check();
    if (!context.mounted) return;
    setState(() => _checking = false);
    if (result.error != null) {
      _toast(context, result.error!);
      return;
    }
    if (!result.hasNewer) {
      _toast(context, '已是最新版本');
      return;
    }
    final url = result.apkUrl ?? result.htmlUrl;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发现新版本'),
        content: Text(
          '当前 ${AppMeta.version} → ${result.latestVersion ?? ''}\n\n'
          '${result.changelog ?? ''}',
          maxLines: 12,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (url == null || url.isEmpty) return;
              final ok = await Browser.open(url);
              if (!ok) await Share.share(url);
            },
            child: const Text('下载安装'),
          ),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LocalStore>();
    return Scaffold(
      // v2.0.1：顶部留白减半（toolbarHeight 56→28）
      appBar: AppBar(toolbarHeight: 28, title: const Text('')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('听书数据',
                style: Theme.of(context).textTheme.labelLarge),
          ),
          ListTile(
            leading: const Icon(Icons.headphones),
            title: const Text('总时长'),
            trailing: Text(formatListeningTime(store.totalListeningMs)),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('今日时长'),
            trailing: Text(formatListeningTime(store.todayListeningMs)),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child:
                Text('外观', style: Theme.of(context).textTheme.labelLarge),
          ),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: const Text('外观模式'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ThemePickerScreen(),
              ),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child:
                Text('音源', style: Theme.of(context).textTheme.labelLarge),
          ),
          ListTile(
            leading: const Icon(Icons.source),
            title: const Text('音源管理'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const SourceManageScreen(),
              ),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child:
                Text('版本', style: Theme.of(context).textTheme.labelLarge),
          ),
          ListTile(
            leading: Icon(Icons.system_update_alt_rounded,
                color: Theme.of(context).colorScheme.primary),
            title: const Text('检查更新'),
            subtitle: Text(
              '当前 v${AppMeta.version} · 对比 GitHub Release',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            trailing: _checking
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary),
                  )
                : null,
            onTap: () => _checkUpdate(context),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child:
                Text('免责声明', style: Theme.of(context).textTheme.labelLarge),
          ),
          ListTile(
            leading: const Icon(Icons.gavel),
            title: const Text('免责声明'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DisclaimerScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ThemePickerScreen extends StatelessWidget {
  const ThemePickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LocalStore>();
    final modes = [
      (0, '浅色'),
      (1, '深色'),
      (2, '跟随系统'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('外观模式')),
      body: ListView(
        children: [
          for (final entry in modes)
            ListTile(
              title: Text(entry.$2),
              trailing: store.themeMode == entry.$1
                  ? const Icon(Icons.check)
                  : null,
              selected: store.themeMode == entry.$1,
              onTap: () => store.setThemeMode(entry.$1),
            ),
        ],
      ),
    );
  }
}
