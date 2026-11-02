import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';

import '../core/covers.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/player.dart';

/// Системное управление плеером: уведомление и экран блокировки с кнопками, кнопки на наушниках
/// (один клик — пауза/игра, два — следующий, три — предыдущий), Bluetooth и гарнитура в машине.
/// Пока играет музыка, это ещё и служба переднего плана: Android не выгружает приложение при свёрнутом экране.
class CaveyAudioHandler extends BaseAudioHandler with SeekHandler {
  CaveyAudioHandler(this.player, this.library, this.covers) {
    player.addListener(_sync);
    player.position.addListener(_position);
    _sync();
  }

  final PlayerController player;
  final LibraryController library;
  final CoverService covers;

  String? _trackId;
  File? _coverFile;
  Duration _reported = Duration.zero;
  DateTime _reportedAt = DateTime.now();
  bool _reportedPlaying = false;

  static Future<CaveyAudioHandler> start(PlayerController p, LibraryController l, CoverService c) =>
      AudioService.init(
        builder: () => CaveyAudioHandler(p, l, c),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'app.cavey.cave_player.playback',
          androidNotificationChannelName: 'Воспроизведение',
          androidNotificationIcon: 'mipmap/ic_launcher',
          fastForwardInterval: Duration(seconds: 10),
          rewindInterval: Duration(seconds: 10),
        ),
      );

  // ── команды из системы ──
  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> stop() async {
    await player.pause();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => player.next();
  @override
  Future<void> skipToPrevious() => player.previous();
  @override
  Future<void> seek(Duration position) => player.seek(position);

  // ── состояние для системы ──
  void _sync() {
    final t = player.current;
    if (t == null) {
      if (_trackId != null) {
        _trackId = null;
        mediaItem.add(null);
      }
      playbackState.add(PlaybackState(processingState: AudioProcessingState.idle, playing: false));
      return;
    }
    if (t.id != _trackId || (mediaItem.value?.duration ?? Duration.zero) != player.duration) {
      final same = t.id == _trackId;
      _trackId = t.id;
      mediaItem.add(MediaItem(
        id: t.id,
        title: t.title,
        artist: t.displayArtist,
        album: t.displayAlbum,
        duration: player.duration > Duration.zero ? player.duration : (t.durationMs != null ? Duration(milliseconds: t.durationMs!) : null),
        artUri: same ? mediaItem.value?.artUri : null,
      ));
      if (!same) unawaited(_loadCover(t));
    }
    _push();
  }

  void _push() {
    final pos = player.position.value;
    _reported = pos;
    _reportedAt = DateTime.now();
    _reportedPlaying = player.playing;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        player.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: player.buffering && !player.playing ? AudioProcessingState.buffering : AudioProcessingState.ready,
      playing: player.playing,
      updatePosition: pos,
      bufferedPosition: pos,
      speed: 1.0,
    ));
  }

  /// Позиция идёт сама (Android считает её по скорости), поэтому сообщаем только о скачках: перемотке
  void _position() {
    if (player.current == null) return;
    final expected = _reportedPlaying ? _reported + DateTime.now().difference(_reportedAt) : _reported;
    if ((player.position.value - expected).abs() > const Duration(milliseconds: 1500)) _push();
  }

  Future<void> _loadCover(Track t) async {
    try {
      var bytes = covers.peek(t, px: 640);
      bytes ??= await covers.forTrack(t, px: 640);
      if (bytes == null || _trackId != t.id) return;
      final old = _coverFile;
      final f = File('${Directory.systemTemp.path}/np_${t.id.hashCode.toUnsigned(32)}.jpg');
      await f.writeAsBytes(bytes, flush: true);
      _coverFile = f;
      if (old != null && old.path != f.path) {
        try {
          await old.delete();
        } catch (_) {}
      }
      final m = mediaItem.value;
      if (m != null && m.id == t.id && _trackId == t.id) mediaItem.add(m.copyWith(artUri: Uri.file(f.path)));
    } catch (_) {}
  }
}
