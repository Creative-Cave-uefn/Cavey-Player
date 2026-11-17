import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cave_mix/cave_mix.dart';
import 'package:media_kit/media_kit.dart' show Media, Player, PlayerLog;

import 'log.dart';

// Дека проигрывателя с тем же интерфейсом, что у Player из media_kit, но с двумя «моторами»:
// • новый движок Cavey Mix (packages/cave_mix) — для треков, которые лежат файлом на диске (кэш);
// • прежний mpv — для потока с Google Диска и форматов, которые движок пока не читает.
// PlayerController работает с двумя такими деками (_p и _q), а они занимают деки 0 и 1 движка.
// Пока DJ-режим не включён в настройках, работает только mpv — всё как раньше.

/// Общий движок приложения: создаётся при первой надобности, опрашивается ~30 раз в секунду
class SharedMix {
  SharedMix._();

  static MixEngine? _engine;
  static bool _failed = false;

  /// Где взять ffmpeg (для M4A, Opus, Ogg). Задаёт PlayerController; путь может появиться позже —
  /// когда приложение докачает ffmpeg, поэтому спрашиваем при каждой загрузке трека.
  static String? Function()? ffmpegPath;
  static String _ffmpegSet = '';

  static void _syncFfmpeg(MixEngine e) {
    final p = ffmpegPath?.call() ?? '';
    if (p == _ffmpegSet) return;
    _ffmpegSet = p;
    e.ffmpegPath = p;
  }
  static Timer? _poll;
  static final Set<HybridDeck> _listeners = {};

  /// Движок или null, если он не запустился (тогда всё играет через mpv)
  static MixEngine? get engine {
    if (_engine != null || _failed) return _engine;
    final e = MixEngine.create();
    if (e == null) {
      _failed = true;
      AppLog.warn('Аудиодвижок Cavey Mix не запустился, играю через mpv', MixEngine.lastCreateError);
      return null;
    }
    e.masterVolume = 1.0;
    final s = e.state();
    AppLog.info('Аудиодвижок Cavey Mix запущен: ${s.sampleRate} Гц');
    _engine = e;
    return e;
  }

  static void _attach(HybridDeck d) {
    _listeners.add(d);
    _poll ??= Timer.periodic(const Duration(milliseconds: 33), (_) => _tick());
  }

  static void _detach(HybridDeck d) {
    _listeners.remove(d);
    if (_listeners.isEmpty) {
      _poll?.cancel();
      _poll = null;
    }
  }

  static void _tick() {
    final e = _engine;
    if (e == null) return;
    final s = e.state();
    for (final d in List.of(_listeners)) {
      d._onEngineState(s);
    }
  }

  static void dispose() {
    _poll?.cancel();
    _poll = null;
    _engine?.dispose();
    _engine = null;
  }
}

/// Потоки событий деки — как Player.stream
class DeckStreams {
  DeckStreams(this.position, this.duration, this.playing, this.buffering, this.completed, this.error, this.log);
  final Stream<Duration> position;
  final Stream<Duration> duration;
  final Stream<bool> playing;
  final Stream<bool> buffering;
  final Stream<bool> completed;
  final Stream<String> error;

  /// Журнал mpv (ошибки фильтров DJ-эффектов); у движка своего журнала нет
  final Stream<PlayerLog> log;
}

/// Текущее состояние деки — как Player.state
class DeckSnapshot {
  DeckSnapshot(this.position, this.duration, this.playing, this.rate, {this.buffering = false});
  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final double rate;
}

class HybridDeck {
  HybridDeck(this.engineDeck, this.engineEnabled);

  /// Номер деки в движке (0 или 1)
  final int engineDeck;

  /// Разрешено ли играть через новый движок (настройка DJ-режима)
  final bool Function() engineEnabled;

  Player? _mpv;
  final List<StreamSubscription<dynamic>> _mpvSubs = [];
  bool _onEngine = false;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _log = StreamController<PlayerLog>.broadcast();

  late final DeckStreams stream = DeckStreams(_position.stream, _duration.stream, _playing.stream, _buffering.stream,
      _completed.stream, _error.stream, _log.stream);

  // состояние, когда играет движок
  Duration _ePos = Duration.zero, _eDur = Duration.zero;
  bool _ePlaying = false, _eBuffering = false, _eCompleted = false;
  int _loadId = 0;
  bool _pendingPlay = false;
  bool _wantPlay = false; // человек хочет, чтобы играло (движок подтверждает с задержкой в один опрос)
  Media? _media;
  double _volume = 100;
  DeckStatus _eStatus = DeckStatus.empty;
  int _eBufferedMs = 0;

  /// Играет ли сейчас через новый движок
  bool get onEngine => _onEngine;

  DeckSnapshot get state {
    if (_onEngine) return DeckSnapshot(_ePos, _eDur, _ePlaying, _eRate, buffering: _eBuffering);
    final p = _mpv;
    if (p == null) return DeckSnapshot(Duration.zero, Duration.zero, false, 1.0);
    return DeckSnapshot(p.state.position, p.state.duration, p.state.playing, p.state.rate, buffering: p.state.buffering);
  }

  Player _mpvPlayer() {
    final existing = _mpv;
    if (existing != null) return existing;
    final p = Player();
    _mpv = p;
    // события mpv пересылаем, только пока дека на mpv
    _mpvSubs.addAll([
      p.stream.position.listen((v) { if (!_onEngine) _position.add(v); }),
      p.stream.duration.listen((v) { if (!_onEngine) _duration.add(v); }),
      p.stream.playing.listen((v) { if (!_onEngine) _playing.add(v); }),
      p.stream.buffering.listen((v) { if (!_onEngine) _buffering.add(v); }),
      p.stream.completed.listen((v) { if (!_onEngine) _completed.add(v); }),
      p.stream.error.listen((v) { if (!_onEngine) _error.add(v); }),
      p.stream.log.listen(_log.add),
    ]);
    unawaited(p.setVolume(_volume));
    return p;
  }

  /// Путь к файлу, если media — локальный файл
  static String? _localPath(Media m) {
    final u = m.uri;
    if (u.startsWith('http://') || u.startsWith('https://')) return null;
    final path = u.startsWith('file://') ? Uri.parse(u).toFilePath() : u;
    return File(path).existsSync() ? path : null;
  }

  Future<void> open(Media media, {bool play = true}) async {
    _media = media;
    final path = _localPath(media);
    final eng = path != null && engineEnabled() ? SharedMix.engine : null;
    if (eng != null && path != null) {
      SharedMix._syncFfmpeg(eng);
      final id = eng.load(engineDeck, path);
      if (id > 0) {
        if (!_onEngine) {
          // переходим с mpv на движок: mpv замолкает
          final p = _mpv;
          if (p != null) await p.stop();
          _onEngine = true;
          SharedMix._attach(this);
        }
        _loadId = id;
        _pendingPlay = play;
        _wantPlay = play;
        _ePos = Duration.zero;
        _eDur = Duration.zero;
        _eCompleted = false;
        _eStatus = DeckStatus.loading;
        _eBufferedMs = 0;
        _eRate = 1.0;
        _setEPlaying(false);
        _setEBuffering(true);
        _position.add(Duration.zero);
        _applyEngineVolume();
        return;
      }
      AppLog.warn('Движок не взял файл, играю через mpv', eng.lastError);
    }
    await _toMpv();
    await _mpvPlayer().open(media, play: play);
  }

  /// Уйти с движка на mpv (дека движка останавливается)
  Future<void> _toMpv() async {
    if (!_onEngine) return;
    _onEngine = false;
    SharedMix._detach(this);
    SharedMix.engine?.unload(engineDeck);
    _pendingPlay = false;
    _ePlaying = false;
    _eBuffering = false;
  }

  void _setEPlaying(bool v) {
    if (_ePlaying == v) return;
    _ePlaying = v;
    _playing.add(v);
  }

  void _setEBuffering(bool v) {
    if (_eBuffering == v) return;
    _eBuffering = v;
    _buffering.add(v);
  }

  // Опрос движка (~30 раз в секунду)
  void _onEngineState(MixState s) {
    if (!_onEngine) return;
    final d = s.decks[engineDeck];
    if (d.loadId != _loadId) return; // состояние ещё от прошлой загрузки
    _eStatus = d.status;
    _eBufferedMs = d.bufferedMs;
    _eRate = d.tempo;
    switch (d.status) {
      case DeckStatus.loading:
      case DeckStatus.empty:
        _setEBuffering(true);
        return;
      case DeckStatus.error:
        final media = _media;
        AppLog.warn('Движок не открыл файл, играю через mpv', SharedMix.engine?.lastError);
        final play = _wantPlay;
        unawaited(() async {
          await _toMpv();
          if (media != null) await _mpvPlayer().open(media, play: play);
        }());
        return;
      case DeckStatus.ready:
      case DeckStatus.playing:
      case DeckStatus.ended:
        break;
    }
    if (d.durationSec > 0) {
      final dur = Duration(microseconds: (d.durationSec * 1e6).round());
      if (dur != _eDur) {
        _eDur = dur;
        _duration.add(dur);
      }
    }
    if (_pendingPlay && d.status == DeckStatus.ready) {
      _pendingPlay = false;
      SharedMix.engine?.play(engineDeck);
    }
    final pos = Duration(microseconds: (d.positionSec * 1e6).round());
    if (pos != _ePos) {
      _ePos = pos;
      _position.add(pos);
    }
    _setEBuffering(_pendingPlay);
    if (d.status == DeckStatus.ended && !_eCompleted) {
      _eCompleted = true;
      _wantPlay = false;
      _setEPlaying(false);
      _completed.add(true);
      return;
    }
    _setEPlaying(_wantPlay && (d.status == DeckStatus.playing || _pendingPlay));
  }

  Future<void> play() async {
    if (_onEngine) {
      _eCompleted = false;
      _pendingPlay = true; // запустим при следующем опросе, как только дека готова
      _wantPlay = true;
      _setEPlaying(true);
      return;
    }
    await _mpv?.play();
  }

  Future<void> pause() async {
    if (_onEngine) {
      _pendingPlay = false;
      _wantPlay = false;
      SharedMix.engine?.pause(engineDeck);
      _setEPlaying(false);
      return;
    }
    await _mpv?.pause();
  }

  Future<void> playOrPause() => state.playing ? pause() : play();

  Future<void> seek(Duration d) async {
    if (_onEngine) {
      SharedMix.engine?.seek(engineDeck, d.inMicroseconds / 1e6);
      _eCompleted = false;
      _ePos = d;
      _position.add(d);
      return;
    }
    await _mpv?.seek(d);
  }

  /// Громкость 0…100, кривая как у mpv (кубическая)
  Future<void> setVolume(double v) async {
    _volume = v;
    if (_onEngine) {
      _applyEngineVolume();
      return;
    }
    await _mpv?.setVolume(v);
  }

  double _eRate = 1.0;

  /// Нативный проигрыватель mpv (для команд фильтров DJ-эффектов). На движке он молчит, команды ему не мешают
  dynamic get platform => _mpvPlayer().platform;

  /// Скорость воспроизведения. На движке — темп Rubber Band (высота сохраняется), на mpv — speed
  Future<void> setRate(double r) async {
    if (_onEngine) {
      _eRate = r;
      SharedMix.engine?.set(engineDeck, MixParam.tempo, r);
      return;
    }
    await _mpvPlayer().setRate(r);
  }

  /// Трек загружен в движок, дека стоит и звука в буфере не меньше [bufferedMs]: можно планировать переход
  bool engineReady({int bufferedMs = 1000}) =>
      _onEngine && !_pendingPlay && _eStatus == DeckStatus.ready && _eBufferedMs >= bufferedMs;

  /// Дека запустится сама по расписанию движка (автомикс): с этого момента она считается «играющей»,
  /// а состояние «играет» появится, когда движок её действительно запустит
  void armScheduledPlay() {
    if (!_onEngine) return;
    _pendingPlay = false;
    _wantPlay = true;
    _eCompleted = false;
  }

  /// Состояние движка (часы, частота) — для планирования, или null, если дека не на движке
  MixState? engineState() => _onEngine ? SharedMix.engine?.state() : null;

  /// Провести громкость деки по кривой точно по часам движка: с кадра [fromClock] в течение [frames] кадров
  /// амплитуда равна амплитуде громкости [baseVolume] (0…100, кривая mpv), умноженной на [f](t), t = 0…1.
  /// Кривая передаётся движку заранее [segments] отрезками, дальше громкость меняется по сэмплам.
  /// false — дека не на движке (тогда громкость ведёт таймер, как раньше).
  bool rampVolume({
    required double baseVolume,
    required int fromClock,
    required int frames,
    required double Function(double t) f,
    int segments = 24,
  }) {
    final e = SharedMix.engine;
    if (!_onEngine || e == null || frames <= 0) return false;
    final a = math.pow((baseVolume / 100).clamp(0.0, 1.0), 3).toDouble();
    for (var i = 0; i < segments; i++) {
      final t0 = i / segments, t1 = (i + 1) / segments;
      e.ramp(engineDeck, MixParam.gain, fromClock + (frames * t0).round(), fromClock + (frames * t1).round(),
          a * f(t0), a * f(t1));
    }
    return true;
  }

  void _applyEngineVolume() {
    final g = math.pow((_volume / 100).clamp(0.0, 1.0), 3).toDouble();
    SharedMix.engine?.set(engineDeck, MixParam.gain, g);
  }

  Future<void> stop() async {
    if (_onEngine) {
      _pendingPlay = false;
      _wantPlay = false;
      SharedMix.engine?.unload(engineDeck);
      _setEPlaying(false);
      _setEBuffering(false);
      _ePos = Duration.zero;
      return;
    }
    await _mpv?.stop();
  }

  Future<void> dispose() async {
    await _toMpv();
    for (final s in _mpvSubs) {
      await s.cancel();
    }
    await _mpv?.dispose();
    for (final c in [_position, _duration, _playing, _buffering, _completed, _error, _log]) {
      await c.close();
    }
  }
}
