import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_meta.dart';
import 'source_registry.dart';
import 'source_router.dart';
import 'storage.dart';

enum ProbeState { idle, checking, ok, unavailable }

class SourceManageScreen extends StatefulWidget {
  const SourceManageScreen({super.key});

  @override
  State<SourceManageScreen> createState() => _SourceManageScreenState();
}

class _SourceManageScreenState extends State<SourceManageScreen> {
  final Map<String, ProbeState> _probes = {};
  final Map<String, int> _latency = {};
  bool _rejected = false;

  static const _rows = <({String id, String name, String? note})>[
    (id: SourceRegistry.tingyou, name: '听友FM', note: null),
    (id: SourceRegistry.bili, name: 'B站', note: null),
    (id: SourceRegistry.ytysxs, name: '悦听', note: '本地索引'),
    (
      id: SourceRegistry.importSource,
      name: '导入',
      note: '不参与搜索与检测'
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeAll());
  }

  Future<void> _probeAll() async {
    final router = context.read<SourceRouter>();
    final targets = SourceRegistry.searchSources;
    if (!mounted) return;
    setState(() {
      for (final id in targets) {
        _probes[id] = ProbeState.checking;
      }
    });
    await Future.wait(targets.map((id) async {
      final started = DateTime.now().millisecondsSinceEpoch;
      try {
        await router
            .discoverCategory(id, _probeCategory(id), page: 1)
            .timeout(const Duration(seconds: 10));
        if (!mounted) return;
        setState(() {
          _probes[id] = ProbeState.ok;
          _latency[id] = DateTime.now().millisecondsSinceEpoch - started;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _probes[id] = ProbeState.unavailable);
      }
    }));
  }

  String _probeCategory(String id) {
    switch (id) {
      case SourceRegistry.bili:
        return 'hot';
      case SourceRegistry.ytysxs:
        return 'yanqing'; // v2.0.2：本地索引分类，零网络——恒可用
      default:
        return 'recommend';
    }
  }

  Widget _badge(String id) {
    final state = _probes[id] ?? ProbeState.idle;
    switch (state) {
      case ProbeState.checking:
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case ProbeState.ok:
        return Text(
          '${_latency[id] ?? 0} ms',
          style: const TextStyle(fontSize: 12, color: Colors.green),
        );
      case ProbeState.unavailable:
        return const Text('不可用',
            style: TextStyle(fontSize: 12, color: Colors.red));
      case ProbeState.idle:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LocalStore>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('音源管理'),
        actions: [
          TextButton(onPressed: _probeAll, child: const Text('检测')),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('选择搜索时使用的音源',
                style: Theme.of(context).textTheme.labelLarge),
          ),
          for (final row in _rows)
            ListTile(
              title: Row(
                children: [
                  Text(row.name),
                  if (row.note != null) ...[
                    const SizedBox(width: 4),
                    Text('（${row.note}）',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                  const Spacer(),
                  _badge(row.id),
                ],
              ),
              trailing: Switch(
                value: row.id == SourceRegistry.importSource
                    ? true
                    : store.isSourceEnabled(row.id),
                onChanged: row.id == SourceRegistry.importSource
                    ? null
                    : (value) {
                        final ok =
                            store.setSourceEnabledGuarded(row.id, value);
                        setState(() => _rejected = !ok);
                        if (!ok) {
                          unawaited(Future<void>.delayed(
                              const Duration(seconds: 2), () {
                            if (mounted) setState(() => _rejected = false);
                          }));
                        }
                      },
              ),
            ),
          if (_rejected)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('至少保留一个音源',
                  style: TextStyle(fontSize: 12, color: Colors.red)),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text('检测为瞬时状态，重新点右上角「检测」可重测',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ],
      ),
    );
  }
}
