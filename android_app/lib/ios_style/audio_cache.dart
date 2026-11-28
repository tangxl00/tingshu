import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// 后续章节音频的本地预缓存。
///
/// - 整章下载到临时目录，按 `(source:albumId chapterIdx)` 稳定命名；
/// - 最多保留 10 个文件 / 300MB，按修改时间淘汰最旧条目；
/// - 并发去重，同一章不会重复下载；
/// - 半文件写入 `.part`，完成后原子改名，避免播放命中残缺缓存。
class AudioCache {
  AudioCache._();

  static final AudioCache instance = AudioCache._();

  static const int maxFiles = 10;
  static const int maxBytes = 300 * 1024 * 1024;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 120),
  ));
  final Map<String, Future<File?>> _inFlight = {};

  /// 文件名净化：key 含冒号、斜杠、问号，不能直接做文件名。
  static String sanitizeKey(String key) {
    return key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  }

  static String keyFor(String albumKey, int chapterIndex) {
    return '$albumKey:$chapterIndex';
  }

  Future<Directory> get _directory async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}chapter_audio_prefetch');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File?> cachedFile(String key) async {
    final dir = await _directory;
    final file = File('${dir.path}${Platform.pathSeparator}${sanitizeKey(key)}.m4a');
    return await file.exists() ? file : null;
  }

  Future<File?> prefetch({
    required String key,
    required ResolvedAudio audio,
  }) async {
    final existing = await cachedFile(key);
    if (existing != null) return existing;

    final running = _inFlight[key];
    if (running != null) return running;

    final task = _download(key, audio);
    _inFlight[key] = task;
    try {
      return await task;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<File?> _download(String key, ResolvedAudio audio) async {
    final dir = await _directory;
    final dest = File('${dir.path}${Platform.pathSeparator}${sanitizeKey(key)}.m4a');
    final part = File('${dest.path}.part');
    try {
      await _dio.downloadUri(
        Uri.parse(audio.url),
        part.path,
        options: Options(headers: audio.headers),
      );
      final length = await part.length();
      if (length <= 0) {
        await part.delete();
        return null;
      }
      if (await dest.exists()) {
        await dest.delete();
      }
      await part.rename(dest.path);
      await _prune();
      return dest;
    } catch (e) {
      debugPrint('[AudioCache] prefetch $key failed: $e');
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
      }
      return null;
    }
  }

  Future<void> _prune() async {
    final dir = await _directory;
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.m4a'))
        .toList();
    if (files.length <= maxFiles) return;

    final entries = <MapEntry<File, DateTime>>[];
    for (final file in files) {
      try {
        final stat = await file.stat();
        entries.add(MapEntry(file, stat.modified));
      } catch (_) {}
    }
    entries.sort((a, b) => a.value.compareTo(b.value));

    while (entries.length > maxFiles) {
      final oldest = entries.removeAt(0);
      try {
        await oldest.key.delete();
      } catch (_) {}
    }

    var total = 0;
    for (final file in dir.listSync().whereType<File>()) {
      try {
        total += await file.length();
      } catch (_) {}
    }
    while (total > maxBytes && entries.isNotEmpty) {
      final oldest = entries.removeAt(0);
      try {
        final size = await oldest.key.length();
        await oldest.key.delete();
        total -= size;
      } catch (_) {}
    }
  }
}
