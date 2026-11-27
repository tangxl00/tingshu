import 'package:dio/dio.dart';

import 'models.dart';
import 'source_registry.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}

Map<String, dynamic> asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return <String, dynamic>{};
}

List<dynamic> asList(Object? value) {
  if (value is List) return value;
  return const [];
}

int asInt(Object? value, [int fallback = 0]) {
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? fallback;
}

String? asString(Object? value) {
  if (value == null) return null;
  final s = '$value';
  return s.isEmpty ? null : s;
}

/// 听友FM JSON API（对应 iOS APIClient + AlbumRepository）。
class TingYouApi {
  TingYouApi({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://tingyou.fm/listening-api/',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: const {
                'User-Agent': 'TingYou-Android/1.0',
              },
            ));

  final Dio _dio;

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final res = await _dio.get<dynamic>(path, queryParameters: query);
      // 听友FM 所有正常响应都带 detail:"成功"（与 chapters/items/data 并存）。
      // 与 iOS APIClient 语义一致：仅以 HTTP 状态码判断成败，Dio 对非 2xx 会抛 DioException。
      return asMap(res.data);
    } on DioException catch (e) {
      throw ApiException('听友FM 请求失败：${e.message ?? e.type.name}');
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    try {
      final res = await _dio.post<dynamic>(path, data: body);
      return asMap(res.data);
    } on DioException catch (e) {
      throw ApiException('听友FM 请求失败：${e.message ?? e.type.name}');
    }
  }

  Future<Map<String, dynamic>> _postForm(
    String path, {
    Map<String, String>? fields,
  }) async {
    try {
      final res = await _dio.post<dynamic>(
        path,
        data: fields,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return asMap(res.data);
    } on DioException catch (e) {
      throw ApiException('听友FM 请求失败：${e.message ?? e.type.name}');
    }
  }

  AppAlbum _albumFromDto(Map<String, dynamic> m) => AppAlbum(
        albumId: asInt(m['id']),
        title: asString(m['title']) ?? '',
        author: asString(m['author']),
        teller: asString(m['teller']),
        // 服务端实际返回 snake_case；保留 camelCase 兼容以便测试桩/未来改版不失效。
        coverUrl: asString(m['cover_url']) ?? asString(m['coverUrl']),
        intro: asString(m['intro']) ?? asString(m['description']) ?? asString(m['synopsis']),
        chapterCount: m['count'] == null ? null : asInt(m['count']),
        playCount: (m['play_count'] ?? m['playCount']) == null
            ? null
            : asInt(m['play_count'] ?? m['playCount']),
        status: m['status'] == null ? null : asInt(m['status']),
        available: m['available'] as bool?,
        source: SourceRegistry.tingyou,
      );

  AppChapter _chapterFromDto(Map<String, dynamic> m) => AppChapter(
        chapterId: asInt(m['id']),
        index: asInt(m['index']),
        title: asString(m['title']) ?? '',
        durationSec: m['duration'] == null ? null : asInt(m['duration']),
      );

  Future<({List<AppAlbum> items, bool hasMore})> rank({
    required String section,
    int page = 1,
  }) async {
    final body = await _get('rank', query: {'section': section, 'page': page});
    final items = asList(body['items'])
        .whereType<Map>()
        .map((e) => _albumFromDto(asMap(e)))
        .toList();
    return (items: items, hasMore: _hasMore(body));
  }

  Future<({List<AppAlbum> items, bool hasMore})> search({
    required String keyword,
    int page = 1,
  }) async {
    final body =
        await _postJson('search', body: {'keyword': keyword, 'page': page});
    final items = asList(body['results'])
        .whereType<Map>()
        .map((e) => _albumFromDto(asMap(e)))
        .toList();
    return (items: items, hasMore: _hasMore(body));
  }

  static bool _hasMore(Map<String, dynamic> body) =>
      body['has_more'] == true || body['hasMore'] == true;

  Future<AppAlbum> detail(int albumId) async {
    final body = await _get('album/$albumId');
    return _albumFromDto(body);
  }

  Future<List<AppChapter>> chapters(int albumId) async {
    final body = await _get('chapters/$albumId');
    return asList(body['chapters'])
        .whereType<Map>()
        .map((e) => _chapterFromDto(asMap(e)))
        .toList();
  }

  Future<String> playUrl(int albumId, int chapterIdx) async {
    final body = await _postForm('play', fields: {
      'album_id': '$albumId',
      'chapter_idx': '$chapterIdx',
    });
    final url = asString(body['play_url']) ?? asString(body['playUrl']);
    if (url == null || url.isEmpty) {
      throw ApiException('听友FM 未返回播放地址');
    }
    return url;
  }
}
