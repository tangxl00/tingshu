import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'source_registry.dart';
import 'tingyou_api.dart';

/// 易听书适配器：与 iOS YitingshuAdapter 对齐。
/// - 详情 / 分类 / 播放页均为 stui HTML；
/// - search.php 命中验证码 gate 时回落本地标题索引；
/// - 音频直链只接受 aod.cos.tx.xmcdn.com，不做验证码绕过。
class YitingshuSource {
  YitingshuSource({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://www.yitingshu.com',
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              responseType: ResponseType.plain,
              headers: const {'Referer': 'https://www.yitingshu.com/'},
            ));

  final Dio _dio;
  final Map<String, _YtsDetail> _detailCache = {};
  Future<List<_IndexRow>>? _indexFuture;
  bool _liveSearchUsable = true;

  static final RegExp _reItem = RegExp(
      r'<a class="stui-vodlist__thumb lazyload" href="/tingshu/(\d+)\.html"[^>]*title="([^"]*)"[^>]*data-original="([^"]*)"');
  static final RegExp _reH1 =
      RegExp(r'<h1 class="title">([\s\S]*?)</h1>', dotAll: true);
  static final RegExp _reCover =
      RegExp(r'class="stui-content__thumb"[\s\S]*?data-original="([^"]+)"',
          dotAll: true);
  static final RegExp _rePlayLink = RegExp(
      r'href="/play/(\d+)-(\d+)-(\d+)\.html"[^>]*>([\s\S]*?)</a>',
      dotAll: true);
  static final RegExp _reNow =
      RegExp(r'var\s+now\s*=\s*"([^"]+)"', dotAll: true);
  static final RegExp _reDescId =
      RegExp(r'id="desc"[\s\S]*?<p>([\s\S]*?)</p>', dotAll: true);
  static final RegExp _reDescClass =
      RegExp(r'class="col-pd"[^>]*>([\s\S]*?)</div>', dotAll: true);
  static final RegExp _reCatPages =
      RegExp(r'<span class="num">\s*(\d+)\s*/\s*(\d+)\s*</span>');
  static final RegExp _reTag = RegExp(r'<[^>]*>');

  static bool isCaptchaGate(String html) =>
      html.contains('vdimgck') || html.contains('系统安全验证');

  static String unescape(String s) {
    var out = s;
    out = out.replaceAll('&amp;amp;', '&amp;');
    out = out.replaceAll('&amp;', '&');
    out = out.replaceAll('&quot;', '"');
    out = out.replaceAll('&#39;', "'");
    out = out.replaceAll('&nbsp;', ' ');
    return out.trim();
  }

  static String? absCover(String raw) {
    var s = unescape(raw).trim();
    if (s.isEmpty) return null;
    if (s.startsWith('@')) {
      return 'https://imagev2.xmcdn.com/${s.substring(1)}';
    }
    if (s.startsWith('//')) return 'https:$s';
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    if (s.startsWith('/')) return 'https://www.yitingshu.com$s';
    return 'https://www.yitingshu.com/$s';
  }

  static String stripTags(String s) => unescape(s.replaceAll(_reTag, ' '));

  static String? _group(RegExp re, String source, [int group = 1]) {
    final m = re.firstMatch(source);
    if (m == null || group >= m.groupCount + 1) return null;
    return m.group(group);
  }

  Future<String> _fetchHtml(String path,
      {Map<String, dynamic>? query, Duration? timeout}) async {
    try {
      final res = await _dio.get<dynamic>(
        path,
        queryParameters: query,
        options: Options(receiveTimeout: timeout),
      );
      return '${res.data ?? ''}';
    } on DioException catch (e) {
      throw ApiException('易听书请求失败：${e.message ?? e.type.name}');
    }
  }

  List<AppAlbum> parseList(String html) {
    final sectionStart = html.indexOf('<ul class="stui-vodlist clearfix">');
    final scope = sectionStart >= 0 ? html.substring(sectionStart) : html;
    final seen = <String>{};
    final out = <AppAlbum>[];
    for (final m in _reItem.allMatches(scope)) {
      final id = m.group(1) ?? '';
      final title = unescape(m.group(2) ?? '');
      if (id.isEmpty || title.isEmpty || !seen.add(id)) continue;
      out.add(AppAlbum(
        albumId: int.tryParse(id) ?? 0,
        title: title,
        coverUrl: absCover(m.group(3) ?? ''),
        source: SourceRegistry.yitingshu,
        detailPath: id,
      ));
    }
    return out;
  }

  Future<({List<AppAlbum> items, bool hasMore})> category(
    String categoryId, {
    int page = 1,
  }) async {
    final html = await _fetchHtml('/yi/$categoryId-$page.html');
    if (isCaptchaGate(html)) {
      throw ApiException('易听书当前触发安全验证，请稍后再试');
    }
    final items = parseList(html);
    final cur = int.tryParse(_group(_reCatPages, html, 1) ?? '');
    final total = int.tryParse(_group(_reCatPages, html, 2) ?? '');
    final hasMore = (cur != null && total != null)
        ? cur < total
        : items.length >= 30;
    return (items: items, hasMore: hasMore);
  }

  Future<List<_IndexRow>> _loadIndex() {
    final existing = _indexFuture;
    if (existing != null) return existing;
    final future = () async {
      final raw = await rootBundle.loadString('assets/yts_index.txt');
      final rows = <_IndexRow>[];
      for (final line in raw.split('\n')) {
        if (line.trim().isEmpty) continue;
        final parts = line.split('|');
        if (parts.length < 2) continue;
        final id = parts[0].trim();
        final title = parts[1].trim();
        if (id.isEmpty || title.isEmpty) continue;
        final cover = parts.length >= 3 ? absCover(parts[2]) : null;
        rows.add(_IndexRow(id, title, cover));
      }
      return rows;
    }();
    _indexFuture = future;
    return future;
  }

  Future<List<AppAlbum>> _searchLocal(String keyword, {int limit = 60}) async {
    final rows = await _loadIndex();
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty) return const [];
    final hits = <({_IndexRow row, int score, int length})>[];
    for (final row in rows) {
      final title = row.title.toLowerCase();
      final idx = title.indexOf(kw);
      if (idx < 0) continue;
      hits.add((row: row, score: idx == 0 ? 0 : 1, length: title.length));
    }
    hits.sort((a, b) {
      if (a.score != b.score) return a.score.compareTo(b.score);
      if (a.length != b.length) return a.length.compareTo(b.length);
      return a.row.id.compareTo(b.row.id);
    });
    return hits.take(limit).map((h) {
      return AppAlbum(
        albumId: int.tryParse(h.row.id) ?? 0,
        title: h.row.title,
        coverUrl: h.row.cover,
        source: SourceRegistry.yitingshu,
        detailPath: h.row.id,
      );
    }).toList();
  }

  Future<List<AppAlbum>> search(String keyword, {int limit = 60}) async {
    if (_liveSearchUsable) {
      try {
        final html = await _fetchHtml(
          '/search.php',
          query: {'searchword': keyword, 'searchtype': '1'},
          timeout: const Duration(seconds: 2),
        );
        if (!isCaptchaGate(html)) {
          final live = parseList(html);
          if (live.isNotEmpty) return live.take(limit).toList();
        } else {
          _liveSearchUsable = false;
        }
      } on ApiException {
        // live 只是补充路径，失败回落本地索引。
      }
    }
    return _searchLocal(keyword, limit: limit);
  }

  Future<_YtsDetail> detail(String bookId) async {
    final cached = _detailCache[bookId];
    if (cached != null &&
        DateTime.now().millisecondsSinceEpoch - cached.fetchedAt < 300000) {
      return cached;
    }
    final html = await _fetchHtml('/tingshu/$bookId.html');
    if (isCaptchaGate(html)) {
      throw ApiException('易听书当前触发安全验证，请稍后再试');
    }
    final title = stripTags(_group(_reH1, html) ?? '');
    if (title.isEmpty) throw ApiException('易听书详情解析失败');
    final coverRaw = _group(_reCover, html);
    final cover = coverRaw == null ? null : absCover(coverRaw);
    final introRaw = _group(_reDescId, html) ?? _group(_reDescClass, html);
    var intro = introRaw == null ? null : stripTags(introRaw);
    if (intro != null && intro.length > 600) intro = intro.substring(0, 600);

    final boundId = _group(_rePlayLink, html, 1);
    final chapters = <AppChapter>[];
    final seen = <int>{};
    for (final m in _rePlayLink.allMatches(html)) {
      final bid = m.group(1) ?? '';
      if (boundId != null && bid != boundId) continue;
      final page = (int.tryParse(m.group(3) ?? '') ?? 0) + 1;
      if (page <= 0 || !seen.add(page)) continue;
      chapters.add(AppChapter(
        chapterId: page,
        index: page - 1,
        title: stripTags(m.group(4) ?? ''),
      ));
    }
    chapters.sort((a, b) => a.index.compareTo(b.index));
    final parsed = _YtsDetail(
      title: title,
      cover: cover,
      intro: intro,
      chapters: chapters,
      fetchedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _detailCache[bookId] = parsed;
    if (_detailCache.length > 8) {
      _detailCache.remove(_detailCache.keys.first);
    }
    return parsed;
  }

  Future<AppAlbum> albumDetail(String bookId) async {
    final d = await detail(bookId);
    return AppAlbum(
      albumId: int.tryParse(bookId) ?? 0,
      title: d.title,
      coverUrl: d.cover,
      intro: d.intro,
      chapterCount: d.chapters.length,
      source: SourceRegistry.yitingshu,
      detailPath: bookId,
    );
  }

  Future<List<AppChapter>> chapters(String bookId) async {
    return (await detail(bookId)).chapters;
  }

  Future<String> playUrl(String bookId, int chapterIdx) async {
    final html = await _fetchHtml('/play/$bookId-0-$chapterIdx.html');
    if (isCaptchaGate(html)) {
      throw ApiException('易听书当前触发安全验证，请稍后再试');
    }
    final raw = _group(_reNow, html);
    if (raw == null) throw ApiException('易听书未返回音频直链');
    final url = unescape(raw).replaceAll(r'\/', '/');
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      throw ApiException('易听书音频地址不可用');
    }
    if (uri.host != 'aod.cos.tx.xmcdn.com') {
      throw ApiException('易听书音频主机不在白名单内');
    }
    return url;
  }
}

class _IndexRow {
  final String id;
  final String title;
  final String? cover;

  const _IndexRow(this.id, this.title, this.cover);
}

class _YtsDetail {
  final String title;
  final String? cover;
  final String? intro;
  final List<AppChapter> chapters;
  final int fetchedAt;

  const _YtsDetail({
    required this.title,
    required this.cover,
    required this.intro,
    required this.chapters,
    required this.fetchedAt,
  });
}

