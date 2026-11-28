import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

/// 悦听有声书（ytysxs.com）适配器——iOS YtysxsAdapter 的 Dart 同构实现。
///
/// v2.0.2 重新接入：
/// - 搜索 / 发现分类：读随包本地索引 assets/ytysxs_index.txt（bookId|标题|封面|分类），
///   零网络——规避站内搜索滑块验证；
/// - 详情：`/<bookId>.html` 解析 og:title / og:image / data-tracks-url；
/// - 章节：AudioIgniter playlist JSON 的 tracks（audio = mp3.ytysxs.top 直链）；
/// - 播放：直链白名单自检（仅 https + *.ytysxs.top）。
///
/// 稳定性：验证页检测命中即抛 ApiException（明确「暂不可用」），不做验证码绕过；
/// 详情/章节进程内缓存 + 索引常驻兜底。
class YtysxsException implements Exception {
  final String message;
  YtysxsException(this.message);
  @override
  String toString() => message;
}

class YtysxsIndexRow {
  final int bookId;
  final String title;
  final String? cover;
  final String category;
  const YtysxsIndexRow({
    required this.bookId,
    required this.title,
    this.cover,
    required this.category,
  });
}

class YtysxsTrack {
  final String title;
  final String subtitle;
  final String audio;
  final String cover;
  const YtysxsTrack({
    required this.title,
    required this.subtitle,
    required this.audio,
    required this.cover,
  });
}

class YtysxsDetail {
  final String title;
  final String? cover;
  final String? intro;
  final List<String> playlistUrls;
  const YtysxsDetail({
    required this.title,
    this.cover,
    this.intro,
    required this.playlistUrls,
  });
}

class YtysxsSource {
  YtysxsSource({Dio? dio})
      : _dio = dio ?? Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 20),
            headers: const {'User-Agent': YtysxsSource.userAgent}));

  static const String src = 'ytysxs';
  static const String base = 'https://www.ytysxs.com';
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const List<String> antibotPatterns = [
    '搜索驗證', '搜索验证', '安全检查', '安全验证',
    'cf-turnstile', 'be_captcha_token', '滑动验证', '滑块验证',
  ];

  final Dio _dio;
  List<YtysxsIndexRow>? _index;
  final Map<int, YtysxsDetail> _detailCache = {};
  final Map<int, List<YtysxsTrack>> _tracksCache = {};

  static bool isAntibot(String text) {
    final lower = text.toLowerCase();
    return antibotPatterns.any((p) => lower.contains(p.toLowerCase()));
  }

  /// 解析索引文本（每行 4 段）。纯静态，便于单测。
  static List<YtysxsIndexRow> parseIndex(String raw) {
    final rows = <YtysxsIndexRow>[];
    final seen = <int>{};
    for (final line in const LineSplitter().convert(raw)) {
      final parts = line.split('|');
      if (parts.length < 4) continue;
      final id = int.tryParse(parts[0].trim());
      if (id == null || parts[1].isEmpty || !seen.add(id)) continue;
      rows.add(YtysxsIndexRow(
        bookId: id,
        title: parts[1],
        cover: parts[2].isEmpty ? null : parts[2],
        category: parts[3],
      ));
    }
    return rows;
  }

  /// 本地索引搜索：前缀命中优先，其次子串；同档短标题优先。
  static List<YtysxsIndexRow> searchIndex(List<YtysxsIndexRow> rows, String keyword) {
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty) return <YtysxsIndexRow>[];
    final prefix = <YtysxsIndexRow>[];
    final substring = <YtysxsIndexRow>[];
    for (final r in rows) {
      final t = r.title.toLowerCase();
      if (t.startsWith('《$kw') || t.startsWith(kw)) {
        prefix.add(r);
      } else if (t.contains(kw)) {
        substring.add(r);
      }
    }
    prefix.sort((a, b) => a.title.length.compareTo(b.title.length));
    substring.sort((a, b) => a.title.length.compareTo(b.title.length));
    return [...prefix, ...substring].take(30).toList();
  }

  static String decodeEntities(String s) {
    return s
        .replaceAll('&#038;', '&')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }

  Future<List<YtysxsIndexRow>> _loadIndex() async {
    final cached = _index;
    if (cached != null) return cached;
    try {
      final raw = await rootBundle.loadString('assets/ytysxs_index.txt');
      _index = parseIndex(raw);
    } catch (_) {
      _index = const [];
    }
    return _index!;
  }

  Future<List<YtysxsIndexRow>> search(String keyword) async {
    return searchIndex(await _loadIndex(), keyword);
  }

  Future<({List<YtysxsIndexRow> rows, bool hasMore})> categoryRows(
    String categoryId, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final all = (await _loadIndex()).where((r) => r.category == categoryId).toList();
    final start = (page - 1) * pageSize;
    if (start >= all.length) return (rows: <YtysxsIndexRow>[], hasMore: false);
    final rawEnd = start + pageSize;
    final end = rawEnd > all.length ? all.length : rawEnd;
    return (rows: all.sublist(start, end), hasMore: end < all.length);
  }

  Future<String> _fetch(String url) async {
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final body = res.data ?? '';
      if (isAntibot(body)) {
        throw YtysxsException('悦听音源暂时不可用（站点验证拦截），请稍后重试或切换其他音源');
      }
      return body;
    } on YtysxsException {
      rethrow;
    } on DioException catch (e) {
      throw YtysxsException('悦听音源暂时不可用（网络：${e.type.name}），请稍后重试');
    }
  }

  Future<YtysxsDetail> detail(int albumId) async {
    final cached = _detailCache[albumId];
    if (cached != null) return cached;
    if (albumId <= 0) throw YtysxsException('书籍标识无效');
    final html = await _fetch('$base/$albumId.html');
    final detail = parseDetailHtml(html);
    _detailCache[albumId] = detail;
    return detail;
  }

  /// 详情页纯函数解析（与 iOS parseDetailHtml 对齐）。
  static YtysxsDetail parseDetailHtml(String html) {
    final title = _first(html, RegExp(r'<meta\s+property="og:title"\s+content="([^"]+)"'));
    final cover = _first(html, RegExp(r'<meta\s+property="og:image"\s+content="([^"]+)"'));
    final intro = _first(html, RegExp(r'<meta\s+property="og:description"\s+content="([^"]+)"'));
    final urls = <String>[];
    final re = RegExp(r'data-tracks-url="([^"]+)"');
    for (final m in re.allMatches(html)) {
      final u = m.group(1) ?? '';
      if (u.contains('audioigniter_playlist_id=') || u.contains('audioigniter/v1/playlist/')) {
        if (!urls.contains(u)) urls.add(u);
      }
    }
    return YtysxsDetail(
      title: decodeEntities(title),
      cover: cover.isEmpty ? null : cover,
      intro: intro.isEmpty ? null : decodeEntities(intro),
      playlistUrls: urls,
    );
  }

  Future<List<YtysxsTrack>> chapters(int albumId) async {
    final cached = _tracksCache[albumId];
    if (cached != null) return cached;
    final d = await detail(albumId);
    final out = <YtysxsTrack>[];
    for (final url in d.playlistUrls) {
      final body = await _fetch(url);
      out.addAll(parseTracksJson(body));
    }
    if (out.isEmpty && d.playlistUrls.isNotEmpty) {
      throw YtysxsException('悦听音源暂时不可用（站点未返回章节），请稍后重试');
    }
    _tracksCache[albumId] = out;
    return out;
  }

  /// AudioIgniter playlist JSON 纯函数解析。
  static List<YtysxsTrack> parseTracksJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <YtysxsTrack>[];
      final out = <YtysxsTrack>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final title = item['title'];
        final audio = item['audio'];
        if (title is! String || title.isEmpty || audio is! String || audio.isEmpty) continue;
        out.add(YtysxsTrack(
          title: decodeEntities(title),
          subtitle: decodeEntities((item['subtitle'] ?? '').toString()),
          audio: audio,
          cover: (item['cover'] ?? '').toString(),
        ));
      }
      return out;
    } catch (_) {
      return <YtysxsTrack>[];
    }
  }

  /// 按 albumId + chapterIdx 取直链（复用章节缓存）。
  Future<String> playUrl(int albumId, int chapterIdx) async {
    final tracks = await chapters(albumId);
    if (chapterIdx < 0 || chapterIdx >= tracks.length) {
      throw YtysxsException('章节索引越界');
    }
    return validateAudioUrl(tracks[chapterIdx].audio);
  }

  /// 音频直链白名单自检（纯函数）：仅 https 且 host 为 ytysxs.top 或其子域。
  static String validateAudioUrl(String url) {
    final u = Uri.tryParse(url);
    if (url.isEmpty || u == null ||
        u.scheme.toLowerCase() != 'https' || u.host.isEmpty) {
      throw YtysxsException('音频地址无效');
    }
    final host = u.host.toLowerCase();
    if (host != 'mp3.ytysxs.top' && !host.endsWith('.ytysxs.top')) {
      throw YtysxsException('音频地址不在悦听白名单内，已拦截');
    }
    return url;
  }

  static String _first(String s, RegExp re) {
    final m = re.firstMatch(s);
    return m?.group(1)?.trim() ?? '';
  }
}
