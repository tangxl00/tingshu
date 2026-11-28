import 'package:dio/dio.dart';

import '../core/app_meta.dart';

/// 检查更新：数据源走 GitHub Releases。
///
/// 仓库地址与 AppMeta.repoUrl 同源；发布时由 android.yml 在 tag 上创建 Release
/// 并附上 APK，App 读取 latest release 的 tag / body / assets 即可。
class UpdateResult {
  const UpdateResult({
    required this.configured,
    this.error,
    this.latestVersion,
    this.latestName,
    this.changelog,
    this.htmlUrl,
    this.apkUrl,
    this.publishedAt,
  });

  /// 是否已配置 GitHub 仓库（未配置时不会发起请求）
  final bool configured;
  final String? error;
  final String? latestVersion;
  final String? latestName;
  final String? changelog;
  final String? htmlUrl;
  final String? apkUrl;

  /// Release 发布日期，格式 yyyy-MM-dd
  final String? publishedAt;

  bool get hasNewer {
    if (!configured) return false;
    final v = latestVersion;
    if (v == null) return false;
    return _compareVersion(AppMeta.version, v) < 0;
  }
}

/// GitHub 语义化版本比较：等价返回 0，a 大返回 1，a 小返回 -1
int _compareVersion(String a, String b) {
  int toInt(String s) => int.tryParse(s.replaceAll(RegExp(r'\D'), '')) ?? 0;
  final pa = a.split('.');
  final pb = b.split('.');
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? toInt(pa[i]) : 0;
    final y = i < pb.length ? toInt(pb[i]) : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

class AppUpdate {
  AppUpdate._();

  /// GitHub 仓库（检查更新数据源）
  static const String githubOwner = 'tangxl00';
  static const String githubRepo = 'tingshu';

  static bool get configured => githubOwner.isNotEmpty && githubRepo.isNotEmpty;

  static String get _apiUrl =>
      'https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest';

  static String get _downloadBase =>
      'https://github.com/$githubOwner/$githubRepo/releases/latest';

  /// 检查最新版本。失败时返回带 error 的结果，不抛异常。
  static Future<UpdateResult> check() async {
    if (!configured) {
      return const UpdateResult(configured: false);
    }
    try {
      final resp = await Dio().get(
        _apiUrl,
        options: Options(
          headers: {'Accept': 'application/vnd.github+json'},
          responseType: ResponseType.json,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      final data = resp.data as Map? ?? {};
      String? apkUrl;
      final assets = data['assets'] as List? ?? const [];
      for (final a in assets) {
        final m = a as Map?;
        final name = '${m?['name'] ?? ''}';
        if (name.endsWith('.apk')) {
          apkUrl = '${m?['browser_download_url'] ?? ''}';
          break;
        }
      }
      final tag = '${data['tag_name'] ?? ''}';
      final published = '${data['published_at'] ?? ''}';
      return UpdateResult(
        configured: true,
        latestVersion: tag.isEmpty ? null : tag.replaceFirst(RegExp(r'^v'), ''),
        latestName: '${data['name'] ?? ''}',
        changelog: '${data['body'] ?? ''}'.trim(),
        htmlUrl: '${data['html_url'] ?? _downloadBase}',
        apkUrl: apkUrl?.isEmpty == true ? null : apkUrl,
        publishedAt: published.length >= 10 ? published.substring(0, 10) : null,
      );
    } catch (_) {
      return UpdateResult(configured: true, error: '检查更新失败，请稍后重试');
    }
  }
}
