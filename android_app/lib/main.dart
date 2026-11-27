import 'package:flutter/material.dart';

import 'ios_style/app.dart';

/// 听书 Android：按 iOS 版 tingshu 的 UI / 功能结构同构实现。
Future<void> main() async {
  await bootstrap();
  runApp(const TingYouApp());
}
