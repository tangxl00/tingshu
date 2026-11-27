import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'source_registry.dart';

/// iOS DataStore + SwiftData 实体的 SharedPreferences 对等实现。
class LocalStore extends ChangeNotifier {
  LocalStore._();
  static final LocalStore instance = LocalStore._();

  static const _kFavorites = 'ty_favorites';
  static const _kHistories = 'ty_histories';
  static const _kImports = 'ty_imported_books';
  static const _kThemeMode = 'theme_mode';
  static const _kListeningTotal = 'listening_total_ms';
  static const _kListeningToday = 'listening_today_ms';
  static const _kListeningDay = 'listening_day';
  static const _kSearchHistory = 'search_history';
  static const _kPlaybackSpeed = 'playback_speed';
  static const _kSourcePrefix = 'source_enabled_';

  SharedPreferences? _prefs;

  List<FavoriteRecord> _favorites = [];
  List<HistoryRecord> _histories = [];
  List<ImportedBook> _imports = [];
  List<String> _searchHistory = [];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    _favorites = _decodeList(prefs.getString(_kFavorites))
        .map((e) => FavoriteRecord.fromJson(e))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _histories = _decodeList(prefs.getString(_kHistories))
        .map((e) => HistoryRecord.fromJson(e))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _imports = _decodeList(prefs.getString(_kImports))
        .map((e) => ImportedBook.fromJson(e))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _searchHistory = prefs.getStringList(_kSearchHistory) ?? [];
    _rolloverDay();
    notifyListeners();
  }

  List<Map<String, dynamic>> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _save() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await Future.wait([
      prefs.setString(
        _kFavorites,
        jsonEncode(_favorites.map((e) => e.toJson()).toList()),
      ),
      prefs.setString(
        _kHistories,
        jsonEncode(_histories.map((e) => e.toJson()).toList()),
      ),
      prefs.setString(
        _kImports,
        jsonEncode(_imports.map((e) => e.toJson()).toList()),
      ),
    ]);
  }

  // ---------- 收藏 ----------

  List<FavoriteRecord> get favorites => List.unmodifiable(_favorites);

  bool isFavorite(String key) => _favorites.any((f) => f.key == key);

  Future<void> addFavorite(AppAlbum album) async {
    if (isFavorite(album.key)) return;
    _favorites.insert(0, FavoriteRecord.fromAlbum(album));
    await _save();
    notifyListeners();
  }

  Future<void> removeFavorite(String key) async {
    _favorites.removeWhere((f) => f.key == key);
    await _save();
    notifyListeners();
  }

  // ---------- 历史 ----------

  List<HistoryRecord> get histories => List.unmodifiable(_histories);

  HistoryRecord? historyFor(String key) {
    for (final h in _histories) {
      if (h.key == key) return h;
    }
    return null;
  }

  Future<void> upsertHistory(HistoryRecord record) async {
    _histories.removeWhere((h) => h.key == record.key);
    _histories.insert(0, record);
    await _save();
    notifyListeners();
  }

  Future<void> deleteHistory(String key) async {
    _histories.removeWhere((h) => h.key == key);
    await _save();
    notifyListeners();
  }

  Future<void> clearHistories() async {
    _histories.clear();
    await _save();
    notifyListeners();
  }

  // ---------- 导入 ----------

  List<ImportedBook> get importedBooks => List.unmodifiable(_imports);

  Future<ImportedBook> importLinks(String title, List<({String uri, String title})> links) async {
    final id = _imports.isEmpty
        ? 1
        : _imports.map((b) => b.id).reduce((a, b) => a > b ? a : b) + 1;
    final book = ImportedBook(
      id: id,
      title: title,
      kind: 'userlink',
      chapters: [
        for (var i = 0; i < links.length; i++)
          AppChapter(
            chapterId: i + 1,
            index: i,
            title: links[i].title,
            uri: links[i].uri,
          ),
      ],
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _imports.insert(0, book);
    await _save();
    notifyListeners();
    return book;
  }

  Future<void> deleteImportedBook(int id) async {
    _imports.removeWhere((b) => b.id == id);
    await _save();
    notifyListeners();
  }

  // ---------- 音源开关 ----------

  bool isSourceEnabled(String source) {
    final value = _prefs?.getBool('$_kSourcePrefix$source');
    return value ?? true;
  }

  List<String> enabledSearchSources() =>
      SourceRegistry.searchSources.where(isSourceEnabled).toList();

  bool setSourceEnabledGuarded(String source, bool enabled) {
    if (!enabled && SourceRegistry.searchSources.contains(source)) {
      final others = SourceRegistry.searchSources
          .where((s) => s != source && isSourceEnabled(s));
      if (others.isEmpty) return false;
    }
    _prefs?.setBool('$_kSourcePrefix$source', enabled);
    notifyListeners();
    return true;
  }

  // ---------- 搜索历史 ----------

  List<String> get searchHistory => List.unmodifiable(_searchHistory);

  List<String> matchingSearchHistory(String keyword) {
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty) return searchHistory;
    return _searchHistory.where((s) => s.toLowerCase().contains(kw)).toList();
  }

  Future<void> addSearchHistory(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    _searchHistory.removeWhere((s) => s.toLowerCase() == kw.toLowerCase());
    _searchHistory.insert(0, kw);
    if (_searchHistory.length > 20) {
      _searchHistory = _searchHistory.sublist(0, 20);
    }
    await _prefs?.setStringList(_kSearchHistory, _searchHistory);
    notifyListeners();
  }

  Future<void> removeSearchHistory(String keyword) async {
    _searchHistory.remove(keyword);
    await _prefs?.setStringList(_kSearchHistory, _searchHistory);
    notifyListeners();
  }

  Future<void> clearSearchHistory() async {
    _searchHistory.clear();
    await _prefs?.setStringList(_kSearchHistory, _searchHistory);
    notifyListeners();
  }

  // ---------- 外观 / 听书时长 / 倍速 ----------

  int get themeMode => _prefs?.getInt(_kThemeMode) ?? 2;

  Future<void> setThemeMode(int mode) async {
    await _prefs?.setInt(_kThemeMode, mode);
    notifyListeners();
  }

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  void _rolloverDay() {
    final prefs = _prefs;
    if (prefs == null) return;
    final today = _todayKey();
    if (prefs.getString(_kListeningDay) != today) {
      prefs.setString(_kListeningDay, today);
      prefs.setInt(_kListeningToday, 0);
    }
  }

  int get totalListeningMs => _prefs?.getInt(_kListeningTotal) ?? 0;

  int get todayListeningMs {
    _rolloverDay();
    return _prefs?.getInt(_kListeningToday) ?? 0;
  }

  Future<void> addListeningTime(int ms) async {
    if (ms <= 0) return;
    _rolloverDay();
    final prefs = _prefs;
    if (prefs == null) return;
    await Future.wait([
      prefs.setInt(_kListeningTotal, (prefs.getInt(_kListeningTotal) ?? 0) + ms),
      prefs.setInt(_kListeningToday, (prefs.getInt(_kListeningToday) ?? 0) + ms),
    ]);
    notifyListeners();
  }

  double get playbackSpeed {
    final value = _prefs?.getDouble(_kPlaybackSpeed) ?? 1.0;
    if (value < 0.5 || value > 4.0) return 1.0;
    return value;
  }

  Future<void> setPlaybackSpeed(double speed) async {
    await _prefs?.setDouble(_kPlaybackSpeed, speed);
    notifyListeners();
  }

  int skipIntro(String albumKey) => _prefs?.getInt('skip_intro_$albumKey') ?? 0;

  int skipOutro(String albumKey) => _prefs?.getInt('skip_outro_$albumKey') ?? 0;

  Future<void> setSkipIntro(String albumKey, int seconds) async {
    await _prefs?.setInt('skip_intro_$albumKey', seconds.clamp(0, 600).toInt());
    notifyListeners();
  }

  Future<void> setSkipOutro(String albumKey, int seconds) async {
    await _prefs?.setInt('skip_outro_$albumKey', seconds.clamp(0, 600).toInt());
    notifyListeners();
  }
}
