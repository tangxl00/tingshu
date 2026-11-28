/// iOS 版 tingshu 同构数据模型。
///
/// 与 iOS Album / Chapter / FavoriteModel / HistoryModel / ImportedBookModel
/// 保持一一对应：albumId 为数值，跨源稳定键为 (source, albumId)，
/// detailPath 保存 bvid / 易听书书 id / 导入书 id 等源内路径。

class AppAlbum {
  final int albumId;
  final String title;
  final String? author;
  final String? teller;
  final String? coverUrl;
  final String? intro;
  final int? chapterCount;
  final int? playCount;
  final int? status;
  final bool? available;
  final String source;
  final String? detailPath;

  const AppAlbum({
    required this.albumId,
    required this.title,
    this.author,
    this.teller,
    this.coverUrl,
    this.intro,
    this.chapterCount,
    this.playCount,
    this.status,
    this.available,
    required this.source,
    this.detailPath,
  });

  AppAlbum copyWith({
    int? albumId,
    String? title,
    String? author,
    String? teller,
    String? coverUrl,
    String? intro,
    int? chapterCount,
    int? playCount,
    int? status,
    bool? available,
    String? source,
    String? detailPath,
  }) {
    return AppAlbum(
      albumId: albumId ?? this.albumId,
      title: title ?? this.title,
      author: author ?? this.author,
      teller: teller ?? this.teller,
      coverUrl: coverUrl ?? this.coverUrl,
      intro: intro ?? this.intro,
      chapterCount: chapterCount ?? this.chapterCount,
      playCount: playCount ?? this.playCount,
      status: status ?? this.status,
      available: available ?? this.available,
      source: source ?? this.source,
      detailPath: detailPath ?? this.detailPath,
    );
  }

  Map<String, dynamic> toJson() => {
        'albumId': albumId,
        'title': title,
        'author': author,
        'teller': teller,
        'coverUrl': coverUrl,
        'intro': intro,
        'chapterCount': chapterCount,
        'playCount': playCount,
        'status': status,
        'available': available,
        'source': source,
        'detailPath': detailPath,
      };

  factory AppAlbum.fromJson(Map<String, dynamic> m) => AppAlbum(
        albumId: int.tryParse('${m['albumId'] ?? 0}') ?? 0,
        title: '${m['title'] ?? ''}',
        author: m['author'] as String?,
        teller: m['teller'] as String?,
        coverUrl: m['coverUrl'] as String?,
        intro: m['intro'] as String?,
        chapterCount: m['chapterCount'] as int?,
        playCount: m['playCount'] as int?,
        status: m['status'] as int?,
        available: m['available'] as bool?,
        source: '${m['source'] ?? ''}',
        detailPath: m['detailPath'] as String?,
      );

  String get key => '$source:$albumId';
}

class AppChapter {
  final int chapterId;
  final int index;
  final String title;
  final int? durationSec;
  /// 导入源的资源地址（本地文件_uri / https 直链）。
  final String? uri;

  const AppChapter({
    required this.chapterId,
    required this.index,
    required this.title,
    this.durationSec,
    this.uri,
  });

  Map<String, dynamic> toJson() => {
        'chapterId': chapterId,
        'index': index,
        'title': title,
        'durationSec': durationSec,
        'uri': uri,
      };

  factory AppChapter.fromJson(Map<String, dynamic> m) => AppChapter(
        chapterId: int.tryParse('${m['chapterId'] ?? 0}') ?? 0,
        index: int.tryParse('${m['index'] ?? 0}') ?? 0,
        title: '${m['title'] ?? ''}',
        durationSec: m['durationSec'] as int?,
        uri: m['uri'] as String?,
      );
}

class FavoriteRecord {
  final String source;
  final int albumId;
  final String title;
  final String? author;
  final String? teller;
  final String? coverUrl;
  final int? chapterCount;
  final String? detailPath;
  final int createdAt;

  const FavoriteRecord({
    required this.source,
    required this.albumId,
    required this.title,
    this.author,
    this.teller,
    this.coverUrl,
    this.chapterCount,
    this.detailPath,
    required this.createdAt,
  });

  factory FavoriteRecord.fromAlbum(AppAlbum album) => FavoriteRecord(
        source: album.source,
        albumId: album.albumId,
        title: album.title,
        author: album.author,
        teller: album.teller,
        coverUrl: album.coverUrl,
        chapterCount: album.chapterCount,
        detailPath: album.detailPath,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

  AppAlbum toAlbum() => AppAlbum(
        albumId: albumId,
        title: title,
        author: author,
        teller: teller,
        coverUrl: coverUrl,
        chapterCount: chapterCount,
        source: source,
        detailPath: detailPath,
      );

  String get key => '$source:$albumId';

  Map<String, dynamic> toJson() => {
        'source': source,
        'albumId': albumId,
        'title': title,
        'author': author,
        'teller': teller,
        'coverUrl': coverUrl,
        'chapterCount': chapterCount,
        'detailPath': detailPath,
        'createdAt': createdAt,
      };

  factory FavoriteRecord.fromJson(Map<String, dynamic> m) => FavoriteRecord(
        source: '${m['source'] ?? ''}',
        albumId: int.tryParse('${m['albumId'] ?? 0}') ?? 0,
        title: '${m['title'] ?? ''}',
        author: m['author'] as String?,
        teller: m['teller'] as String?,
        coverUrl: m['coverUrl'] as String?,
        chapterCount: m['chapterCount'] as int?,
        detailPath: m['detailPath'] as String?,
        createdAt: int.tryParse('${m['createdAt'] ?? 0}') ?? 0,
      );
}

class HistoryRecord {
  final String source;
  final int albumId;
  final String albumTitle;
  final String? coverUrl;
  final int chapterIdx;
  final String chapterTitle;
  final int positionMs;
  final int durationMs;
  final String? detailPath;
  final int updatedAt;

  const HistoryRecord({
    required this.source,
    required this.albumId,
    required this.albumTitle,
    this.coverUrl,
    required this.chapterIdx,
    required this.chapterTitle,
    required this.positionMs,
    required this.durationMs,
    this.detailPath,
    required this.updatedAt,
  });

  AppAlbum toAlbum() => AppAlbum(
        albumId: albumId,
        title: albumTitle,
        coverUrl: coverUrl,
        source: source,
        detailPath: detailPath,
      );

  String get key => '$source:$albumId';

  int get percent {
    if (durationMs <= 0) return 0;
    final p = (positionMs * 100) ~/ durationMs;
    return p < 0 ? 0 : (p > 100 ? 100 : p);
  }

  /// 精确进度文案：第 N 章 MM:SS（章号为音源原生 1 基，positionMs 为章内位置）。
  String get chapterProgressText {
    final sec = positionMs > 0 ? positionMs ~/ 1000 : 0;
    final m = sec ~/ 60;
    final s = sec % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return '第$chapterIdx章 $mm:$ss';
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        'albumId': albumId,
        'albumTitle': albumTitle,
        'coverUrl': coverUrl,
        'chapterIdx': chapterIdx,
        'chapterTitle': chapterTitle,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'detailPath': detailPath,
        'updatedAt': updatedAt,
      };

  factory HistoryRecord.fromJson(Map<String, dynamic> m) => HistoryRecord(
        source: '${m['source'] ?? ''}',
        albumId: int.tryParse('${m['albumId'] ?? 0}') ?? 0,
        albumTitle: '${m['albumTitle'] ?? ''}',
        coverUrl: m['coverUrl'] as String?,
        chapterIdx: int.tryParse('${m['chapterIdx'] ?? 0}') ?? 0,
        chapterTitle: '${m['chapterTitle'] ?? ''}',
        positionMs: int.tryParse('${m['positionMs'] ?? 0}') ?? 0,
        durationMs: int.tryParse('${m['durationMs'] ?? 0}') ?? 0,
        detailPath: m['detailPath'] as String?,
        updatedAt: int.tryParse('${m['updatedAt'] ?? 0}') ?? 0,
      );
}

class ImportedBook {
  final int id;
  final String title;
  final String kind;
  final String? meta;
  final List<AppChapter> chapters;
  final int createdAt;

  const ImportedBook({
    required this.id,
    required this.title,
    required this.kind,
    this.meta,
    required this.chapters,
    required this.createdAt,
  });

  AppAlbum toAlbum() => AppAlbum(
        albumId: id,
        title: title,
        source: 'import',
        detailPath: '$id',
        chapterCount: chapters.length,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'kind': kind,
        'meta': meta,
        'chapters': chapters.map((c) => c.toJson()).toList(),
        'createdAt': createdAt,
      };

  factory ImportedBook.fromJson(Map<String, dynamic> m) => ImportedBook(
        id: int.tryParse('${m['id'] ?? 0}') ?? 0,
        title: '${m['title'] ?? ''}',
        kind: '${m['kind'] ?? ''}',
        meta: m['meta'] as String?,
        chapters: (m['chapters'] as List? ?? [])
            .map((e) => AppChapter.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        createdAt: int.tryParse('${m['createdAt'] ?? 0}') ?? 0,
      );
}

/// 源返回的音频地址 + 请求头。
class ResolvedAudio {
  final String url;
  final Map<String, String> headers;
  /// B站镜像链：首条为 url，失败时播放器按顺序切换。
  final List<String> alternatives;

  const ResolvedAudio({
    required this.url,
    this.headers = const {},
    this.alternatives = const [],
  });
}
