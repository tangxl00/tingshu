import 'package:flutter/material.dart';

/// v2.0.0：免责声明独立页面，5 条文案与 iOS 端逐字一致。
class DisclaimerScreen extends StatelessWidget {
  const DisclaimerScreen({super.key});

  static const List<String> items = [
    '1.应用内所有音频、封面、文字等内容均来自第三方平台的公开链接，版权归原作者及相关权利人所有。本应用不存储、不修改、不二次分发任何内容。',
    '2.内容仅供个人学习、研究与试听交流使用，请勿用于任何商业用途;请勿下载、录制或传播相关内容',
    '3.请在试听后支持正版:如喜欢某部作品，建议前往官方平台购买、订阅或支持作者。',
    '4.若权利人认为本应用侵犯其合法权益，请告知开发者，我们将在核实后及时处理(包括但不限于移除相关入口)。',
    '5.因使用本应用产生的任何直接或间接后果，由使用者自行承担。',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('免责声明')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                item,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
              ),
            ),
        ],
      ),
    );
  }
}
