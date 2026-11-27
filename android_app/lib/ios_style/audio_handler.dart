import 'package:audio_service/audio_service.dart';

import 'playback_manager.dart';

/// Android MediaSession 桥接：与旧 BiliAudioHandler 解耦，直接驱动新版
/// PlaybackManager，保证锁屏/通知栏控制的是 iOS 同构播放器。
class IosAudioHandler extends BaseAudioHandler {
  IosAudioHandler(this._manager) {
    mediaItem.add(const MediaItem(id: 'idle', title: '听书'));
    sync();
  }

  final PlaybackManager _manager;

  void sync() {
    final album = _manager.currentAlbum;
    final chapterIdx = _manager.currentChapterIdx;
    final chapters = _manager.currentChapters;
    final chapter = chapterIdx >= 0 && chapterIdx < chapters.length
        ? chapters[chapterIdx]
        : null;

    mediaItem.add(MediaItem(
      id: album == null
          ? 'idle'
          : '${album.source}:${album.albumId}:${chapter?.chapterId ?? 0}',
      title: chapter?.title ?? _manager.currentAlbumTitle,
      album: _manager.currentAlbumTitle,
      artist: album?.author ?? '听书',
      artUri: album?.coverUrl == null ? null : Uri.tryParse(album!.coverUrl!),
      duration: _manager.durationMs > 0
          ? Duration(milliseconds: _manager.durationMs)
          : null,
    ));

    playbackState.add(PlaybackState(
      controls: const [
        MediaControl.skipToPrevious,
        MediaControl.rewind,
        MediaControl.play,
        MediaControl.fastForward,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
      },
      androidCompactActionIndices: const [0, 2, 4],
      processingState: _manager.isChapterLoading
          ? AudioProcessingState.loading
          : (_manager.hasMedia
              ? AudioProcessingState.ready
              : AudioProcessingState.idle),
      playing: _manager.isPlaying,
      speed: _manager.speed,
      updatePosition: Duration(milliseconds: _manager.positionMs),
      bufferedPosition: Duration(milliseconds: _manager.durationMs),
    ));
    queue.add(chapters
        .map((c) => MediaItem(
              id: '${album?.source}:${album?.albumId}:${c.chapterId}',
              title: c.title,
              album: _manager.currentAlbumTitle,
            ))
        .toList());
  }

  @override
  Future<void> play() => _manager.resume();

  @override
  Future<void> pause() => _manager.pause();

  @override
  Future<void> seek(Duration position) =>
      _manager.seek(position.inMilliseconds);

  @override
  Future<void> skipToNext() => _manager.nextChapter();

  @override
  Future<void> skipToPrevious() => _manager.previousChapter();

  @override
  Future<void> fastForward() => _manager.seekRelative(15000);

  @override
  Future<void> rewind() => _manager.seekRelative(-15000);

  @override
  Future<void> stop() => _manager.pause();
}
