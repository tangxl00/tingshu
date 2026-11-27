import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'models.dart';
import 'source_router.dart';
import 'tingyou_api.dart';
import 'storage.dart';

enum SleepMode { off, chapterEnd, minutes15, minutes30, minutes45, minutes60 }

class SleepConfig {
  final SleepMode mode;
  final DateTime? startedAt;

  const SleepConfig({required this.mode, this.startedAt});

  int get minutes {
    switch (mode) {
      case SleepMode.minutes15:
        return 15;
      case SleepMode.minutes30:
        return 30;
      case SleepMode.minutes45:
        return 45;
      case SleepMode.minutes60:
        return 60;
      default:
        return 0;
    }
  }
}

/// iOS PlaybackManager 对等实现：章节队列 + 断点续播 + 倍速 + 定时 + 失败重试。
class PlaybackManager extends ChangeNotifier {
  PlaybackManager._({
    required SourceRouter router,
    required LocalStore store,
  })  : _router = router,
        _store = store {
    _player.stream.position.listen(_onPosition);
    _player.stream.duration.listen(_onDuration);
    _player.stream.playing.listen(_onPlaying);
    _player.stream.completed.listen(_onCompleted);
  }

  static final PlaybackManager instance = PlaybackManager._(
    router: SourceRouter(importedBooks: () => LocalStore.instance.importedBooks),
    store: LocalStore.instance,
  );

  final Player _player = Player();
  final SourceRouter _router;
  final LocalStore _store;

  AppAlbum? _currentAlbum;
  List<AppChapter> _currentChapters = const [];
  int _currentChapterIdx = -1;
  ResolvedAudio? _resolved;
  int _alternativeIdx = 0;

  int _positionMs = 0;
  int _durationMs = 0;
  bool _isPlaying = false;
  bool _isChapterLoading = false;
  String? _playbackError;

  SleepConfig _sleepConfig = const SleepConfig(mode: SleepMode.off);
  Timer? _sleepTimer;
  bool _sleepStopAtChapterEnd = false;

  int _lastHistoryWriteMs = 0;
  int _lastListeningTickMs = 0;
  bool _silentWrite = false;

  AppAlbum? get currentAlbum => _currentAlbum;
  List<AppChapter> get currentChapters => List.unmodifiable(_currentChapters);
  int get currentChapterIdx => _currentChapterIdx;
  String get currentAlbumTitle => _currentAlbum?.title ?? '';
  String get currentChapterTitle {
    if (_currentChapterIdx < 0 || _currentChapterIdx >= _currentChapters.length) {
      return '';
    }
    return _currentChapters[_currentChapterIdx].title;
  }

  String? get coverUrl => _currentAlbum?.coverUrl;
  int get positionMs => _positionMs;
  int get durationMs => _durationMs;
  bool get isPlaying => _isPlaying;
  bool get isChapterLoading => _isChapterLoading;
  String? get playbackError => _playbackError;
  SleepConfig get sleepConfig => _sleepConfig;
  double get speed {
    final value = _player.state.rate;
    return value > 0 ? value : (_store.playbackSpeed);
  }

  bool get hasMedia => _currentAlbum != null;

  int get skipIntro => _currentAlbum == null
      ? 0
      : _store.skipIntro(_currentAlbum!.key);
  int get skipOutro => _currentAlbum == null
      ? 0
      : _store.skipOutro(_currentAlbum!.key);

  /// 启动恢复：读最新历史 → 重建队列 → 静默定位，不自动出声。
  Future<void> restoreLastSession() async {
    final latest = _store.histories.isEmpty ? null : _store.histories.first;
    if (latest == null) return;
    try {
      final chapters = await _router.chapters(latest.toAlbum());
      if (chapters.isEmpty) return;
      var pos = 0;
      for (var i = 0; i < chapters.length; i++) {
        if (chapters[i].index == latest.chapterIdx) {
          pos = i;
          break;
        }
      }
      prepareQueue(
        album: latest.toAlbum(),
        chapters: chapters,
        start: pos,
        startPosMs: latest.positionMs,
        silentWrite: true,
      );
    } catch (e) {
      debugPrint('[PlaybackManager] restore failed: $e');
    }
  }

  void prepareQueue({
    required AppAlbum album,
    required List<AppChapter> chapters,
    required int start,
    int startPosMs = 0,
    bool silentWrite = false,
  }) {
    if (chapters.isEmpty) return;
    _currentAlbum = album;
    _currentChapters = chapters;
    _currentChapterIdx = start.clamp(0, chapters.length - 1).toInt();
    _positionMs = startPosMs;
    _durationMs = (chapters[_currentChapterIdx].durationSec ?? 0) * 1000;
    _playbackError = null;
    _silentWrite = silentWrite;
    _resolved = null;
    _alternativeIdx = 0;
    notifyListeners();
  }

  Future<void> playQueue({
    required AppAlbum album,
    required List<AppChapter> chapters,
    int start = 0,
    int startPosMs = 0,
    bool silentWrite = false,
  }) async {
    prepareQueue(
      album: album,
      chapters: chapters,
      start: start,
      startPosMs: startPosMs,
      silentWrite: silentWrite,
    );
    await _openCurrent(autoPlay: true, startPosMs: startPosMs);
  }

  Future<void> playChapterAt(int index) async {
    if (index < 0 || index >= _currentChapters.length) return;
    final resumeMs = index == _currentChapterIdx ? _positionMs : 0;
    _currentChapterIdx = index;
    notifyListeners();
    await _openCurrent(autoPlay: true, startPosMs: resumeMs);
  }

  Future<void> _openCurrent({
    required bool autoPlay,
    int startPosMs = 0,
  }) async {
    final album = _currentAlbum;
    if (album == null || _currentChapterIdx < 0) return;
    final chapter = _currentChapters[_currentChapterIdx];
    _isChapterLoading = true;
    _playbackError = null;
    notifyListeners();

    try {
      final resolved = await _router.playUrl(album, chapter);
      _resolved = resolved;
      _alternativeIdx = 0;
      await _openResolved(
        resolved,
        autoPlay: autoPlay,
        startPosMs: startPosMs,
      );
      await _player.setRate(_store.playbackSpeed);
    } catch (e) {
      _playbackError = '加载失败：${_describe(e)}';
      _isChapterLoading = false;
      notifyListeners();
    }
  }

  Future<void> _openResolved(
    ResolvedAudio resolved, {
    required bool autoPlay,
    int startPosMs = 0,
  }) async {
    final urls = <String>[resolved.url, ...resolved.alternatives];
    Object? lastError;
    for (var i = _alternativeIdx; i < urls.length; i++) {
      try {
        await _player.open(
          Media(urls[i], httpHeaders: resolved.headers),
          play: autoPlay,
        );
        _alternativeIdx = i;
        if (startPosMs > 0) {
          await _player.seek(Duration(milliseconds: startPosMs));
        }
        _isPlaying = autoPlay;
        _isChapterLoading = false;
        _playbackError = null;
        notifyListeners();
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? '没有可用的音频地址';
  }

  Future<void> retryCurrentChapter() async {
    await _openCurrent(autoPlay: true, startPosMs: 0);
  }

  Future<void> togglePlayPause() async {
    if (!hasMedia || _currentChapterIdx < 0) return;
    if (_resolved == null || _playbackError != null) {
      await _openCurrent(autoPlay: true, startPosMs: _positionMs);
      return;
    }
    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
    _isPlaying = !_isPlaying;
    notifyListeners();
  }

  Future<void> pause() async {
    if (!_isPlaying) return;
    await _player.pause();
    _isPlaying = false;
    await flushProgress();
    notifyListeners();
  }

  Future<void> resume() async {
    if (_isPlaying) return;
    if (_resolved == null || _playbackError != null) {
      await _openCurrent(autoPlay: true, startPosMs: _positionMs);
      return;
    }
    await _player.play();
    _isPlaying = true;
    notifyListeners();
  }

  Future<void> seek(int positionMs) async {
    if (positionMs < 0) return;
    _positionMs = positionMs;
    try {
      await _player.seek(Duration(milliseconds: positionMs));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> seekRelative(int deltaMs) async {
    await seek(_positionMs + deltaMs);
  }

  Future<void> nextChapter() async {
    if (_currentChapterIdx + 1 >= _currentChapters.length) return;
    await flushProgress();
    await playChapterAt(_currentChapterIdx + 1);
  }

  Future<void> previousChapter() async {
    if (_positionMs > 3000) {
      await seek(0);
      return;
    }
    if (_currentChapterIdx - 1 < 0) return;
    await flushProgress();
    await playChapterAt(_currentChapterIdx - 1);
  }

  Future<void> setSpeed(double speed) async {
    final clamped = speed.clamp(0.5, 4.0).toDouble();
    await _player.setRate(clamped);
    await _store.setPlaybackSpeed(clamped);
    notifyListeners();
  }

  void applySleepTimer(SleepConfig config) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepStopAtChapterEnd = config.mode == SleepMode.chapterEnd;
    _sleepConfig = config;
    if (config.minutes > 0) {
      _sleepTimer = Timer(Duration(minutes: config.minutes), () {
        unawaited(pause());
        _sleepConfig = const SleepConfig(mode: SleepMode.off);
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> setIntroSkip(int seconds) async {
    if (_currentAlbum == null) return;
    await _store.setSkipIntro(_currentAlbum!.key, seconds);
    notifyListeners();
  }

  Future<void> setOutroSkip(int seconds) async {
    if (_currentAlbum == null) return;
    await _store.setSkipOutro(_currentAlbum!.key, seconds);
    notifyListeners();
  }

  Future<void> toggleFavorite() async {
    final album = _currentAlbum;
    if (album == null) return;
    if (_store.isFavorite(album.key)) {
      await _store.removeFavorite(album.key);
    } else {
      await _store.addFavorite(album);
    }
    notifyListeners();
  }

  Future<void> flushProgress() async {
    final album = _currentAlbum;
    if (album == null || _currentChapterIdx < 0) return;
    if (_currentChapterIdx >= _currentChapters.length) return;
    if (_silentWrite) return;
    final chapter = _currentChapters[_currentChapterIdx];
    final now = DateTime.now().millisecondsSinceEpoch;
    await _store.upsertHistory(HistoryRecord(
      source: album.source,
      albumId: album.albumId,
      albumTitle: album.title,
      coverUrl: album.coverUrl,
      chapterIdx: chapter.index,
      chapterTitle: chapter.title,
      positionMs: _positionMs,
      durationMs: _durationMs,
      detailPath: album.detailPath,
      updatedAt: now,
    ));
    _lastHistoryWriteMs = now;
  }

  void _onPosition(Duration position) {
    final ms = position.inMilliseconds;
    _positionMs = ms;

    final intro = skipIntro * 1000;
    if (intro > 0 && ms > 0 && ms < intro && _isPlaying) {
      _player.seek(Duration(milliseconds: intro));
    } else {
      final duration = _durationMs > 0
          ? _durationMs
          : (_player.state.duration.inMilliseconds);
      final outro = skipOutro * 1000;
      if (outro > 0 && duration > outro && ms > duration - outro && _isPlaying) {
        unawaited(nextChapter());
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_isPlaying && now - _lastListeningTickMs >= 1000) {
      final delta = now - _lastListeningTickMs;
      _lastListeningTickMs = now;
      unawaited(_store.addListeningTime(delta));
    }
    if (_isPlaying && now - _lastHistoryWriteMs >= 5000) {
      unawaited(flushProgress());
    }
    notifyListeners();
  }

  void _onDuration(Duration duration) {
    final ms = duration.inMilliseconds;
    if (ms > 0) _durationMs = ms;
    notifyListeners();
  }

  void _onPlaying(bool playing) {
    if (_isPlaying != playing) {
      _isPlaying = playing;
      if (!playing) unawaited(flushProgress());
      _lastListeningTickMs = DateTime.now().millisecondsSinceEpoch;
      notifyListeners();
    }
  }

  void _onCompleted(bool completed) {
    if (!completed) return;
    unawaited(flushProgress());
    if (_sleepStopAtChapterEnd) {
      applySleepTimer(const SleepConfig(mode: SleepMode.off));
      unawaited(pause());
      return;
    }
    unawaited(nextChapter());
  }

  String _describe(Object error) {
    if (error is ApiException) return error.message;
    if (error is String) return error;
    return error.toString();
  }
}
