import 'dart:io';

import 'package:flutter/services.dart';

/// 打开外部链接（走原生 Intent，避免额外依赖 url_launcher）
class Browser {
  Browser._();

  static const _channel = MethodChannel('tingyou/browser');

  /// 用系统浏览器打开；失败返回 false（调用方可提示复制链接）
  static Future<bool> open(String url) async {
    if (url.trim().isEmpty) return false;
    if (!Platform.isAndroid) {
      // 非 Android 平台暂无通道，退化为复制到剪贴板由调用方提示
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>(
        'open',
        {'url': url},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}