import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/network/api_config.dart';
import '../core/network/bili_client.dart';
import '../models/audio_stream.dart';
import '../models/book.dart';
import '../services/bili_api.dart';
import 'models.dart';
import 'source_registry.dart';
import 'tingyou_api.dart';

class AggregateOutcome {
  final List<AppAlbum> albums;
  final List<String> failedSources;

  const AggregateOutcome({
    required this.albums,
    required this.failedSources,
  });

  bool get allFailed => albums.isEmpty && failedSources.isNotEmpty;
}

/// 多音源路由：search / detail / chapters / playUrl / discoverCategory
/// 五条链路全部按 source 路由，与 iOS SourceRouter 一一对应。
class SourceRouter {
  SourceRouter({
    TingYouApi? tingyou,
    BiliApi? bili,
    List<ImportedBook> Function()? importedBooks,
  })  : _tingyou = tingyou ?? TingYouApi(),
        _bili = bili ?? BiliApi.instance,
        _importedBooks = importedBooks;

  final TingYouApi _tingyou;
  final BiliApi _bili;
  final List<ImportedBook> Function()? _importedBooks;

  /// B站 albumId 稳定哈希（FNV-1a 64），与 iOS SourceRouter.biliAlbumId 一致。
  static int biliAlbumId(String bvid) {
    // FNV-1a 64：Dart int 为有符号 64 位，故用 BigInt 计算后映射回 int。
    final modulus = BigInt.one << 64;
    final prime = BigInt.parse('0x100000001b3');
    var hash = BigInt.parse('0xcbf29ce484222325');
    for (final unit in bvid.codeUnits) {
      hash = ((hash ^ BigInt.from(unit)) * prime) % modulus;
    }
    if (hash >= (BigInt.one << 63)) hash -= modulus;
    return hash.toInt();
  }

  AppAlbum _albumFromBili(Book b) => AppAlbum(
        albumId: biliAlbumId(b.bvid),
        title: b.cleanTitle,
        author: b.author.isNotEmpty ? b.author : null,
        coverUrl: b.pic.isEmpty ? null : b.pic,
        intro: b.desc.isEmpty ? null : b.desc,
        chapterCount: b.pages,
        playCount: b.play,
        available: true,
        source: SourceRegistry.bili,
        detailPath: b.bvid,
      );

  Future<List<AppAlbum>> search(String source, String keyword) async {
    switch (source) {
      case SourceRegistry.tingyou:
        return (await _tingyou.search(keyword: keyword)).items;
      case SourceRegistry.bili:
        final books = await _bili.search(keyword);
        return books.map(_albumFromBili).toList();
      case SourceRegistry.importSource:
        final kw = keyword.trim().toLowerCase();
        return (_importedBooks?.call() ?? const <ImportedBook>[])
            .where((b) => b.title.toLowerCase().contains(kw))
            .map((b) => b.toAlbum())
            .toList();
      default:
        throw ApiException('未知音源：$source');
    }
  }

  /// 聚合搜索：先到的源先上屏；失败源如实列出，不拖垮整体。
  Future<AggregateOutcome> aggregateSearch(
    String keyword,
    List<String> enabledSources, {
    void Function(AggregateOutcome partial)? onPartial,
  }) async {
    final merged = <String, AppAlbum>{};
    final failed = <String>[];

    void emit() {
      onPartial?.call(AggregateOutcome(
        albums: merged.values.toList(),
        failedSources: List<String>.from(failed),
      ));
    }

    await Future.wait(enabledSources.map((src) async {
      try {
        final items = await search(src, keyword).timeout(const Duration(seconds: 20));
        for (final item in items) {
          merged.putIfAbsent(item.key, () => item);
        }
        emit();
      } catch (e) {
        debugPrint('[SourceRouter] search $src failed: $e');
        failed.add(SourceRegistry.displayName(src));
        emit();
      }
    }));

    return AggregateOutcome(
      albums: merged.values.toList(),
      failedSources: failed,
    );
  }

  Future<AppAlbum?> albumDetail(AppAlbum album) async {
    switch (album.source) {
      case SourceRegistry.tingyou:
        return _tingyou.detail(album.albumId);
      case SourceRegistry.bili:
        final id = album.detailPath;
        if (id == null || id.isEmpty) return null;
        final book = await _bili.detail(id);
        return _albumFromBili(book).copyWith(
          chapterCount: book.chapters?.length ?? book.pages,
        );
      case SourceRegistry.importSource:
        final books = _importedBooks?.call() ?? const <ImportedBook>[];
        for (final b in books) {
          if (b.id == album.albumId) return b.toAlbum();
        }
        return null;
      default:
        return null;
    }
  }

  Future<List<AppChapter>> chapters(AppAlbum album) async {
    switch (album.source) {
      case SourceRegistry.tingyou:
        return _tingyou.chapters(album.albumId);
      case SourceRegistry.bili:
        final bvid = album.detailPath;
        if (bvid == null || bvid.isEmpty) return const [];
        // 与 iOS playablePages 链路一致：优先 pagelist，失败回落 view。
        final pages = await _bili.pageList(bvid);
        return pages
            .map((p) => AppChapter(
                  chapterId: p.cid,
                  index: p.page - 1,
                  title: p.part,
                  durationSec: p.duration > 0 ? p.duration : null,
                ))
            .toList();
      case SourceRegistry.importSource:
        final books = _importedBooks?.call() ?? const <ImportedBook>[];
        for (final b in books) {
          if (b.id == album.albumId) return b.chapters;
        }
        return const [];
      default:
        throw ApiException('该音源已下架或暂不支持');
    }
  }

  Future<({List<AppAlbum> items, bool hasMore})> discoverCategory(
    String source,
    String categoryId, {
    int page = 1,
  }) async {
    switch (source) {
      case SourceRegistry.tingyou:
        return _tingyou.rank(section: categoryId, page: page);
      case SourceRegistry.bili:
        final cat = DiscoverCatalog.find(source, categoryId);
        final keyword = cat?.keyword ?? categoryId;
        final books = await _bili.search(
          keyword,
          page: page,
          order: cat?.order ?? 'totalrank',
        );
        return (
          items: books.map(_albumFromBili).toList(),
          hasMore: books.length >= 20,
        );
      default:
        return (items: const <AppAlbum>[], hasMore: false);
    }
  }

  Future<ResolvedAudio> playUrl(AppAlbum album, AppChapter chapter) async {
    switch (album.source) {
      case SourceRegistry.tingyou:
        final url = await _tingyou.playUrl(album.albumId, chapter.index);
        return ResolvedAudio(url: url);
      case SourceRegistry.bili:
        final bvid = album.detailPath;
        if (bvid == null || bvid.isEmpty) {
          throw ApiException('B站视频标识缺失');
        }
        final audio = await _bili.playUrl(bvid, chapter.chapterId.toInt());
        final candidates = <String>[];
        for (final t in audio.tracks) {
          if (t.baseUrl.isNotEmpty) candidates.add(t.baseUrl);
          candidates.addAll(t.backupUrls);
        }
        final flac = audio.flac;
        if (flac != null && flac.baseUrl.isNotEmpty) {
          candidates.insert(0, flac.baseUrl);
        }
        final dolby = audio.dolby;
        if (dolby != null && dolby.baseUrl.isNotEmpty) {
          candidates.insert(0, dolby.baseUrl);
        }
        final unique = <String>{};
        final ordered = candidates.where((u) => unique.add(u)).toList();
        if (ordered.isEmpty) throw ApiException('B站未返回可用音频地址');
        return ResolvedAudio(
          url: ordered.first,
          alternatives: ordered.skip(1).toList(),
          headers: {
            'Referer': BiliEndpoints.home,
            'Origin': BiliEndpoints.home,
            'User-Agent': BiliEndpoints.userAgent,
          },
        );
      case SourceRegistry.importSource:
        final uri = chapter.uri;
        if (uri == null || uri.isEmpty) throw ApiException('导入章节没有地址');
        return ResolvedAudio(url: uri);
      default:
        throw ApiException('该音源已下架，无法播放');
    }
  }

  Future<void> warmupBili() async {
    try {
      await BiliClient.instance.warmupIfNeeded();
    } catch (e) {
      debugPrint('[SourceRouter] bili warmup failed: $e');
    }
  }
}
