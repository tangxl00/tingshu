import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/book.dart';

/// 书架上的书 + 阅读进度（本地持久化）
class ShelfBook {
  Book book;
  int lastCid;
  int lastChapterIndex;
  int positionMs;
  int chapterDurationMs;
  int updatedAt;

  /// 已听完的章节 cid 列表（用于「已听 ✓」区分）
  List<int> doneCids;

  /// 实测到的总章节数（播放时从真实章节列表写入）
  ///
  /// 不能用 book.pages 当准：它来自搜索结果里的 videos 字段，
  /// 实测《三体》7 个分P拿到的却是 1，整本进度会因此算成单章进度。
  int totalChapters;

  /// 每章已听进度（cid → 0~1），用于算**整本书**的准确百分比
  ///
  /// 只存比例不存具体位置：数据量小，且跳着听（听第2章一点、又跳到第6章）
  /// 也能算准。老数据没有这个字段，会退回「听到第几章」的估算。
  Map<int, double> chapterProgress;

  ShelfBook({
    required this.book,
    this.lastCid = 0,
    this.lastChapterIndex = 0,
    this.positionMs = 0,
    this.chapterDurationMs = 0,
    int? updatedAt,
    List<int>? doneCids,
    this.totalChapters = 0,
    Map<int, double>? chapterProgress,
  })  : updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        doneCids = doneCids ?? <int>[],
        chapterProgress = chapterProgress ?? <int, double>{};

  Map<String, dynamic> toJson() => {
        'book': book.toJson(),
        'lastCid': lastCid,
        'lastChapterIndex': lastChapterIndex,
        'positionMs': positionMs,
        'chapterDurationMs': chapterDurationMs,
        'updatedAt': updatedAt,
        'doneCids': doneCids,
        'totalChapters': totalChapters,
        'chapterProgress':
            chapterProgress.map((k, v) => MapEntry('$k', v)),
      };

  factory ShelfBook.fromJson(Map<String, dynamic> m) {
    final raw = (m['chapterProgress'] as Map?) ?? const {};
    final progress = <int, double>{};
    raw.forEach((k, v) {
      final cid = int.tryParse('$k') ?? 0;
      final f = (v as num?)?.toDouble() ?? 0;
      if (cid != 0 && f > 0) progress[cid] = f.clamp(0.0, 1.0);
    });
    return ShelfBook(
      book: Book.fromJson((m['book'] as Map).cast<String, dynamic>()),
      lastCid: int.tryParse('${m['lastCid'] ?? 0}') ?? 0,
      lastChapterIndex: int.tryParse('${m['lastChapterIndex'] ?? 0}') ?? 0,
      positionMs: int.tryParse('${m['positionMs'] ?? 0}') ?? 0,
      chapterDurationMs: int.tryParse('${m['chapterDurationMs'] ?? 0}') ?? 0,
      updatedAt: int.tryParse('${m['updatedAt'] ?? 0}') ?? 0,
      doneCids: (m['doneCids'] as List?)
              ?.map((e) => int.tryParse('$e') ?? 0)
              .where((e) => e != 0)
              .toList() ??
          <int>[],
      totalChapters: int.tryParse('${m['totalChapters'] ?? 0}') ?? 0,
      chapterProgress: progress,
    );
  }

  /// 精确到秒的播放位置（h:mm:ss / mm:ss）
  String get positionText {
    if (positionMs <= 0) return '00:00';
    final p = Duration(milliseconds: positionMs);
    final h = p.inHours;
    final m = p.inMinutes % 60;
    final s = p.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '$mm:$ss';
  }

  String get progressText =>
      positionMs <= 0 ? '未开始' : '读到 $positionText';

  /// 这本书是否已经有收听进度（用于书架是否显示进度徽标）
  bool get hasProgress => positionMs > 0 || doneCids.isNotEmpty;

  /// **整本书**的播放进度（0~1）
  ///
  /// 注意：之前这里是 `positionMs / chapterDurationMs`，那是**当前这一章**
  /// 的进度，用户看到「3%」会以为是整本书听了 3%，其实只是某一章听了 3%。
  ///
  /// 现在优先用逐章进度表累加（跳着听也准）；老数据没有逐章记录时，
  /// 退回「听到第几章 + 当前章比例」的位置估算。
  double get percent {
    // 章节总数优先用实测值，其次书里带的列表，最后才是 book.pages
    var total = totalChapters > 0
        ? totalChapters
        : (book.chapters?.length ??
            (book.pages > 0 ? book.pages : 0));

    // book.pages 可能偏小（实测《三体》7 个分P只拿到 1）。
    // 既然已经听到第 lastChapterIndex 章了，总数至少得比它大，
    // 否则会算出「听了 150%」这种荒谬值。
    final atLeast = lastChapterIndex + 1;
    if (total < atLeast) total = atLeast;

    if (total <= 0) {
      // 极少数拿不到章节数的情况：退回单章进度，总比不给强
      if (chapterDurationMs <= 0 || positionMs <= 0) return 0;
      return (positionMs / chapterDurationMs).clamp(0.0, 1.0);
    }

    var sum = 0.0;
    for (final v in chapterProgress.values) {
      sum += v.clamp(0.0, 1.0);
    }

    if (sum == 0) {
      // 老数据（没有逐章进度表）：按「听到第几章」估算位置
      var done = doneCids.length;
      if (done == 0 && lastChapterIndex > 0) done = lastChapterIndex;
      if (done > total) done = total;
      var cur = 0.0;
      if (chapterDurationMs > 0 &&
          positionMs > 0 &&
          lastChapterIndex >= done) {
        cur = (positionMs / chapterDurationMs).clamp(0.0, 1.0);
      }
      sum = done + cur;
    }

    return (sum / total).clamp(0.0, 1.0);
  }
}

class ShelfStore extends ChangeNotifier {
  ShelfStore._();
  static final ShelfStore instance = ShelfStore._();

  static const _key = 'tingyou_shelf';

  final List<ShelfBook> _books = [];

  /// 按最近收听时间倒序返回（返回副本，避免排序副作用影响内部列表）
  List<ShelfBook> get books {
    final sorted = [..._books]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(sorted);
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _books
        ..clear()
        ..addAll(list.map((e) => ShelfBook.fromJson((e as Map).cast<String, dynamic>())));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_books.map((b) => b.toJson()).toList()),
    );
  }

  bool isOnShelf(String bvid) => _books.any((b) => b.book.bvid == bvid);

  ShelfBook? byBvid(String bvid) {
    for (final b in _books) {
      if (b.book.bvid == bvid) return b;
    }
    return null;
  }

  /// 加入书架（已存在则刷新元数据）
  Future<void> add(Book book, {ShelfBook? withProgress}) async {
    final existing = byBvid(book.bvid);
    if (existing != null) {
      existing.book = book; // 刷新元数据（封面/标题等可能已变化）
      existing.updatedAt = DateTime.now().millisecondsSinceEpoch;
    } else {
      _books.add(
        withProgress ??
            ShelfBook(book: book, lastCid: book.chapters?.first.cid ?? 0),
      );
    }
    notifyListeners();
    await _save();
  }

  Future<void> remove(String bvid) async {
    _books.removeWhere((b) => b.book.bvid == bvid);
    notifyListeners();
    await _save();
  }

  /// 补全实测的章节总数（书架打开时后台拉取一次）
  ///
  /// book.pages 来自搜索结果，可能不准（实测《三体》7 章拿到 1），
  /// 而整本书进度必须除以真实章节数。
  Future<void> setTotalChapters(String bvid, int n) async {
    if (n <= 0) return;
    final b = byBvid(bvid);
    if (b == null || b.totalChapters == n) return;
    b.totalChapters = n;
    _save();
    notifyListeners();
  }

  /// 更新某个章节的播放进度
  Future<ShelfBook?> updateProgress(
    String bvid, {
    required int cid,
    required int chapterIndex,
    required int positionMs,
    required int chapterDurationMs,
    /// 实测的总章节数（播放器从真实章节列表传入），用于整本书进度
    int totalChapters = 0,
  }) async {
    final existing = byBvid(bvid);
    if (existing == null) return null;
    existing
      ..lastCid = cid
      ..lastChapterIndex = chapterIndex
      ..positionMs = positionMs
      ..chapterDurationMs = chapterDurationMs
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;

    // 记下实测的总章节数，整本书进度才有可靠的分母
    if (totalChapters > 0) existing.totalChapters = totalChapters;

    // 记下这一章听到哪了（整本书进度的分子来源）
    if (cid != 0 && chapterDurationMs > 0) {
      final f = (positionMs / chapterDurationMs).clamp(0.0, 1.0);
      // 只前进不后退：单章回退不重听不该让整本进度倒退
      final prev = existing.chapterProgress[cid] ?? 0;
      if (f > prev) existing.chapterProgress[cid] = f;
      // 上限保护：超过 2000 条时清掉「刚开始听」的条目
      if (existing.chapterProgress.length > 2000) {
        existing.chapterProgress
            .removeWhere((_, v) => v < 0.05);
      }
    }

    _save();
    notifyListeners();
    return existing;
  }

  /// 标记某章节为「已听完」（幂等）
  Future<void> markChapterDone(String bvid, int cid) async {
    final existing = byBvid(bvid);
    if (existing == null || cid == 0) return;
    if (existing.doneCids.contains(cid)) return;
    existing.doneCids.add(cid);
    // 上限保护：只保留最近 800 条，避免极端长篇把本地存储撑爆
    if (existing.doneCids.length > 800) {
      existing.doneCids = existing.doneCids.sublist(
        existing.doneCids.length - 800,
      );
    }
    notifyListeners();
    await _save();
  }

  /// 某章节是否已听完
  bool isChapterDone(String bvid, int cid) {
    final existing = byBvid(bvid);
    if (existing == null) return false;
    return existing.doneCids.contains(cid);
  }

  /// 本书已听完的章节数
  int doneCount(String bvid) => byBvid(bvid)?.doneCids.length ?? 0;
}