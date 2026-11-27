import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_meta.dart';
import 'shelf_screen.dart';
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
  @override
  Widget build(BuildContext context) {
    final store = context.watch<LocalStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
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
          ListTile(
            leading: const Icon(Icons.menu_book),
            title: const Text('我的书架'),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.onOpenShelf,
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
                Text('关于', style: Theme.of(context).textTheme.labelLarge),
          ),
          ListTile(
            title: const Text('版本'),
            trailing: Text('${AppMeta.version} (6)'),
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
