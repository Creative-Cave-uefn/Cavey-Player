/// Cavey Mix: Dart-обёртка над нативным движком DJ-режима (packages/cave_mix/src).
///
/// Время движка — «часы» [MixState.clock] в кадрах. Всё, что должно случиться точно
/// (старт деки, автоматизация громкости, EQ, темпа), задаётся в кадрах часов.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Параметры деки (см. cave_mix.h)
enum MixParam {
  gain, // фейдер 0…1
  trimDb, // выравнивание громкости, дБ
  eqLow, // −1 — выключено, 0 — нейтрально, +1 — +6 дБ
  eqMid,
  eqHigh,
  filter, // −1…0 — ФНЧ, 0…+1 — ФВЧ
  filterRes, // 0…1
  tempo, // 1.0 — родной темп
  echoSend, // 0…1: сколько звука деки уходит в эхо (до фейдера)
  echoTime, // задержка эха, секунды
  echoFeedback, // обратная связь эха 0…0,95
}

/// Форма кривой автоматизации
enum MixCurve { linear, equalPowerIn, equalPowerOut, smooth, step }

enum DeckStatus { empty, loading, ready, playing, ended, error }

class DeckState {
  final DeckStatus status;
  final int loadId;
  final double positionSec;
  final double durationSec;
  final double tempo;
  final double peak;
  final int startClock;
  final bool stretching;
  final int bufferedMs;

  const DeckState({
    required this.status,
    required this.loadId,
    required this.positionSec,
    required this.durationSec,
    required this.tempo,
    required this.peak,
    required this.startClock,
    required this.stretching,
    required this.bufferedMs,
  });
}

class MixState {
  final int sampleRate;
  final int clock;
  final int underruns;
  final double masterPeak;
  final double limiterGainDb;
  final List<DeckState> decks;

  const MixState(this.sampleRate, this.clock, this.underruns, this.masterPeak, this.limiterGainDb, this.decks);

  /// Часы в секундах
  double get clockSec => sampleRate > 0 ? clock / sampleRate : 0;
}

// ---------------------------------------------------------------- нативные структуры

final class _CmDeckState extends Struct {
  @Int32()
  external int status;
  @Int32()
  external int loadId;
  @Double()
  external double positionSec;
  @Double()
  external double durationSec;
  @Double()
  external double tempo;
  @Double()
  external double peak;
  @Int64()
  external int startClock;
  @Int32()
  external int stretching;
  @Int32()
  external int bufferedMs;
}

final class _CmState extends Struct {
  @Int32()
  external int apiVersion;
  @Int32()
  external int sampleRate;
  @Int64()
  external int clock;
  @Int64()
  external int underruns;
  @Double()
  external double masterPeak;
  @Double()
  external double limiterGainDb;
  @Array(2)
  external Array<_CmDeckState> deck;
}

typedef _CreateN = Pointer<Void> Function(Int32, Int32);
typedef _CreateD = Pointer<Void> Function(int, int);
typedef _VoidPN = Void Function(Pointer<Void>);
typedef _VoidPD = void Function(Pointer<Void>);
typedef _ErrN = Pointer<Utf8> Function(Pointer<Void>);
typedef _LoadN = Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>, Double);
typedef _LoadD = int Function(Pointer<Void>, int, Pointer<Utf8>, double);
typedef _DeckN = Void Function(Pointer<Void>, Int32);
typedef _DeckD = void Function(Pointer<Void>, int);
typedef _DeckClockN = Void Function(Pointer<Void>, Int32, Int64);
typedef _DeckClockD = void Function(Pointer<Void>, int, int);
typedef _DeckDoubleN = Void Function(Pointer<Void>, Int32, Double);
typedef _DeckDoubleD = void Function(Pointer<Void>, int, double);
typedef _SetN = Void Function(Pointer<Void>, Int32, Int32, Double);
typedef _SetD = void Function(Pointer<Void>, int, int, double);
typedef _RampN = Void Function(Pointer<Void>, Int32, Int32, Int64, Int64, Double, Double, Int32);
typedef _RampD = void Function(Pointer<Void>, int, int, int, int, double, double, int);
typedef _DoubleN = Void Function(Pointer<Void>, Double);
typedef _DoubleD = void Function(Pointer<Void>, double);
typedef _IntN = Void Function(Pointer<Void>, Int32);
typedef _IntD = void Function(Pointer<Void>, int);
typedef _StateN = Void Function(Pointer<Void>, Pointer<_CmState>);
typedef _StateD = void Function(Pointer<Void>, Pointer<_CmState>);
typedef _StrN = Void Function(Pointer<Void>, Pointer<Utf8>);
typedef _StrD = void Function(Pointer<Void>, Pointer<Utf8>);
typedef _RenderN = Int32 Function(Pointer<Void>, Pointer<Float>, Int32);
typedef _RenderD = int Function(Pointer<Void>, Pointer<Float>, int);

class _Lib {
  _Lib(DynamicLibrary l)
      : create = l.lookupFunction<_CreateN, _CreateD>('cm_create'),
        destroy = l.lookupFunction<_VoidPN, _VoidPD>('cm_destroy'),
        lastError = l.lookupFunction<_ErrN, _ErrN>('cm_last_error'),
        load = l.lookupFunction<_LoadN, _LoadD>('cm_load'),
        unload = l.lookupFunction<_DeckN, _DeckD>('cm_unload'),
        setFfmpeg = l.lookupFunction<_StrN, _StrD>('cm_set_ffmpeg'),
        playAt = l.lookupFunction<_DeckClockN, _DeckClockD>('cm_play_at'),
        pause = l.lookupFunction<_DeckN, _DeckD>('cm_pause'),
        seek = l.lookupFunction<_DeckDoubleN, _DeckDoubleD>('cm_seek'),
        stopAt = l.lookupFunction<_DeckClockN, _DeckClockD>('cm_stop_at'),
        set = l.lookupFunction<_SetN, _SetD>('cm_set'),
        ramp = l.lookupFunction<_RampN, _RampD>('cm_ramp'),
        clearAutomation = l.lookupFunction<_DeckN, _DeckD>('cm_clear_automation'),
        masterVolume = l.lookupFunction<_DoubleN, _DoubleD>('cm_set_master_volume'),
        setPaused = l.lookupFunction<_IntN, _IntD>('cm_set_paused'),
        getState = l.lookupFunction<_StateN, _StateD>('cm_get_state'),
        render = l.lookupFunction<_RenderN, _RenderD>('cm_render');

  final _CreateD create;
  final _VoidPD destroy;
  final _ErrN lastError;
  final _LoadD load;
  final _DeckD unload;
  final _StrD setFfmpeg;
  final _DeckClockD playAt;
  final _DeckD pause;
  final _DeckDoubleD seek;
  final _DeckClockD stopAt;
  final _SetD set;
  final _RampD ramp;
  final _DeckD clearAutomation;
  final _DoubleD masterVolume;
  final _IntD setPaused;
  final _StateD getState;
  final _RenderD render;
}

DynamicLibrary _open() {
  if (Platform.isWindows) return DynamicLibrary.open('cave_mix.dll');
  if (Platform.isLinux || Platform.isAndroid) return DynamicLibrary.open('libcave_mix.so');
  return DynamicLibrary.process(); // macOS / iOS: библиотека вшита в приложение
}

/// Аудиодвижок с двумя деками. Создаётся один на приложение.
class MixEngine {
  MixEngine._(this._l, this._e) : _state = calloc<_CmState>();

  static const decks = 2;

  final _Lib _l;
  Pointer<Void> _e;
  final Pointer<_CmState> _state;

  /// Создать движок. null — нативная библиотека не загрузилась или нет аудиоустройства;
  /// причина — в [lastCreateError].
  /// [offline] — без устройства: звук забирается через [render] (тесты, рендер переходов).
  static MixEngine? create({int sampleRate = 0, bool offline = false}) {
    try {
      final l = _Lib(_open());
      final e = l.create(sampleRate, offline ? 1 : 0);
      if (e == nullptr) {
        lastCreateError = 'cm_create вернул ошибку (нет аудиоустройства?)';
        return null;
      }
      return MixEngine._(l, e);
    } catch (e) {
      lastCreateError = '$e';
      return null;
    }
  }

  static String lastCreateError = '';

  bool get isDisposed => _e == nullptr;

  void dispose() {
    if (_e == nullptr) return;
    _l.destroy(_e);
    _e = nullptr;
    calloc.free(_state);
  }

  String get lastError => _e == nullptr ? '' : _l.lastError(_e).toDartString();

  /// Загрузить файл (асинхронно). Возвращает id загрузки или −1.
  int load(int deck, String path, {double startSec = 0}) {
    final p = path.toNativeUtf8(allocator: malloc);
    try {
      return _l.load(_e, deck, p, startSec);
    } finally {
      malloc.free(p);
    }
  }

  void unload(int deck) => _l.unload(_e, deck);

  /// Путь к ffmpeg: им движок читает M4A/AAC, Opus, Ogg и прочие форматы, которых нет во встроенных декодерах
  set ffmpegPath(String path) {
    final p = path.toNativeUtf8(allocator: malloc);
    try {
      _l.setFfmpeg(_e, p);
    } finally {
      malloc.free(p);
    }
  }

  /// Запустить деку на кадре часов [atClock]; null — как только будет звук.
  void play(int deck, {int? atClock}) => _l.playAt(_e, deck, atClock ?? -1);
  void pause(int deck) => _l.pause(_e, deck);
  void seek(int deck, double sec) => _l.seek(_e, deck, sec);
  void stopAt(int deck, int atClock) => _l.stopAt(_e, deck, atClock);

  void set(int deck, MixParam p, double value) => _l.set(_e, deck, p.index, value);

  /// Автоматизация параметра на отрезке часов [fromClock, toClock)
  void ramp(int deck, MixParam p, int fromClock, int toClock, double from, double to,
          {MixCurve curve = MixCurve.linear}) =>
      _l.ramp(_e, deck, p.index, fromClock, toClock, from, to, curve.index);

  void clearAutomation(int deck) => _l.clearAutomation(_e, deck);

  /// Громкость мастера 0…1 (кубическая кривая, как у mpv)
  set masterVolume(double v) => _l.masterVolume(_e, v);

  /// Пауза всего движка: часы стоят
  set paused(bool v) => _l.setPaused(_e, v ? 1 : 0);

  MixState state() {
    _l.getState(_e, _state);
    final s = _state.ref;
    return MixState(s.sampleRate, s.clock, s.underruns, s.masterPeak, s.limiterGainDb, [
      for (var i = 0; i < decks; i++)
        DeckState(
          status: DeckStatus.values[s.deck[i].status.clamp(0, DeckStatus.values.length - 1).toInt()],
          loadId: s.deck[i].loadId,
          positionSec: s.deck[i].positionSec,
          durationSec: s.deck[i].durationSec,
          tempo: s.deck[i].tempo,
          peak: s.deck[i].peak,
          startClock: s.deck[i].startClock,
          stretching: s.deck[i].stretching != 0,
          bufferedMs: s.deck[i].bufferedMs,
        ),
    ]);
  }

  /// Только для offline-движка: вывести [frames] кадров стерео в [out] (длиной ≥ frames·2)
  int render(Pointer<Float> out, int frames) => _l.render(_e, out, frames);
}

// ---------------------------------------------------------------- анализ треков

typedef _AnCreateN = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Pointer<Utf8>>);
typedef _AnCreateD = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Pointer<Utf8>>);
typedef _AnFileN = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _FreeN = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);

/// Анализатор треков (нативный): доли и даунбиты нейросетью Beat This!, сетка темпа, громкость EBU R128,
/// тональность, энергия по тактам, фразы, точки микса. Результат — JSON профиля v2 (ТЗ, раздел 3.3).
/// Вызовы блокирующие и долгие (секунды на трек): держите анализатор в отдельном изоляте.
class TrackAnalyzer {
  TrackAnalyzer._(this._destroy, this._analyze, this._free, this._a);

  final _VoidPD _destroy;
  final _AnFileN _analyze;
  final _FreeD _free;
  Pointer<Void> _a;

  /// [ortLib] — onnxruntime.dll / libonnxruntime.so; [melModel] — mel_spectrogram.onnx;
  /// [beatModel] — Beat This! в ONNX. [threads] 0 — по числу ядер. Ошибка — исключение с текстом.
  static TrackAnalyzer create({required String ortLib, required String melModel, required String beatModel, int threads = 0}) {
    final l = _open();
    final create = l.lookupFunction<_AnCreateN, _AnCreateD>('cm_analyzer_create');
    final destroy = l.lookupFunction<_VoidPN, _VoidPD>('cm_analyzer_destroy');
    final analyze = l.lookupFunction<_AnFileN, _AnFileN>('cm_analyze_file');
    final free = l.lookupFunction<_FreeN, _FreeD>('cm_free');
    final a = ortLib.toNativeUtf8(allocator: malloc), m = melModel.toNativeUtf8(allocator: malloc);
    final b = beatModel.toNativeUtf8(allocator: malloc);
    final err = malloc<Pointer<Utf8>>()..value = nullptr;
    try {
      final h = create(a, m, b, threads, err);
      if (h == nullptr) {
        final msg = err.value == nullptr ? 'анализатор не создался' : err.value.toDartString();
        if (err.value != nullptr) free(err.value.cast());
        throw StateError(msg);
      }
      return TrackAnalyzer._(destroy, analyze, free, h);
    } finally {
      malloc.free(a);
      malloc.free(m);
      malloc.free(b);
      malloc.free(err);
    }
  }

  /// JSON профиля трека. [ffmpeg] — для M4A/Opus/Ogg (может быть пустым). Ошибка — исключение с текстом.
  String analyzeFile(String path, {String ffmpeg = ''}) {
    if (_a == nullptr) throw StateError('анализатор закрыт');
    final p = path.toNativeUtf8(allocator: malloc), f = ffmpeg.toNativeUtf8(allocator: malloc);
    final err = malloc<Pointer<Utf8>>()..value = nullptr;
    try {
      final r = _analyze(_a, p, f, err);
      if (r == nullptr) {
        final msg = err.value == nullptr ? 'анализ не удался' : err.value.toDartString();
        if (err.value != nullptr) _free(err.value.cast());
        throw StateError(msg);
      }
      final s = r.toDartString();
      _free(r.cast());
      return s;
    } finally {
      malloc.free(p);
      malloc.free(f);
      malloc.free(err);
    }
  }

  void dispose() {
    if (_a == nullptr) return;
    _destroy(_a);
    _a = nullptr;
  }
}
