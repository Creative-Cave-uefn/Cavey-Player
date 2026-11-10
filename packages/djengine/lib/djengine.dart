import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Эффекты DJ-пульта
enum DjFx { none, echo, reverb, flanger }

/// К чему подключён эффект
enum DjFxTarget { off, deckA, deckB, master }

/// Тонкая обёртка над нативным движком (packages/djengine/src/djengine.cpp). Все вызовы быстрые и безопасные из основного потока:
/// движок сам играет в своём аудиопотоке. Если библиотеку загрузить не удалось, [open] вернёт null
class DjEngine {
  /// Частота, на которой движок работает; треки нужно приводить к ней (ffmpeg -ar)
  static const sampleRate = 44100;

  final ffi.Pointer<ffi.Void> _h;
  final _Api _api;
  bool _disposed = false;

  DjEngine._(this._h, this._api);

  /// Загружает библиотеку и открывает звуковое устройство; null — не получилось (нет библиотеки или устройства)
  static DjEngine? open({bool device = true, String? libraryPath}) {
    try {
      final lib = ffi.DynamicLibrary.open(libraryPath ?? (Platform.isWindows ? 'djengine.dll' : 'libdjengine.so'));
      final api = _Api(lib);
      final h = api.create(sampleRate, device ? 1 : 0);
      if (h == ffi.nullptr) return null;
      final e = DjEngine._(h, api);
      if (device && api.deviceStart(h) != 0) {
        e.dispose();
        return null;
      }
      return e;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _api.deviceStop(_h);
    _api.destroy(_h);
  }

  /// Загружает файл с сырым PCM (float32, стерео, [sampleRate] Гц). Возвращает число кадров или отрицательное число при ошибке
  int load(int deck, String path) {
    final p = path.toNativeUtf8();
    try {
      return _api.load(_h, deck, p);
    } finally {
      malloc.free(p);
    }
  }

  void unload(int deck) => _api.unload(_h, deck);
  void play(int deck, bool on) => _api.play(_h, deck, on ? 1 : 0);
  bool isPlaying(int deck) => _api.isPlaying(_h, deck) != 0;

  /// Позиция и перемотка в кадрах
  void seek(int deck, double frames) => _api.seek(_h, deck, frames);
  double pos(int deck) => _api.pos(_h, deck);
  int length(int deck) => _api.length(_h, deck);

  void setTempo(int deck, double ratio) => _api.setTempo(_h, deck, ratio);
  void setKeylock(int deck, bool on) => _api.setKeylock(_h, deck, on ? 1 : 0);

  /// Сдвиг тональности в полутонах; работает при включённом keylock
  void setPitch(int deck, double semitones) => _api.setPitch(_h, deck, semitones);

  void setTrim(int deck, double db) => _api.setTrim(_h, deck, db);
  void setFader(int deck, double v) => _api.setFader(_h, deck, v);
  void setEq(int deck, double lowDb, double midDb, double highDb) => _api.setEq(_h, deck, lowDb, midDb, highDb);
  void setFilter(int deck, double v) => _api.setFilter(_h, deck, v);
  void setLoop(int deck, double inFrames, double outFrames, bool active) => _api.setLoop(_h, deck, inFrames, outFrames, active ? 1 : 0);

  /// Кроссфейдер -1 (дека A) … 1 (дека B); [sharp] — резкая кривая (сумма), иначе постоянная мощность
  void setCrossfader(double x, {bool sharp = false}) => _api.setCrossfader(_h, x, sharp ? 1 : 0);
  void setMaster(double gain) => _api.setMaster(_h, gain);

  /// Эффект [unit] (0 или 1). [p1], [p2]: эхо — задержка мс и обратная связь; реверберация — комната и демпфирование (0…1);
  /// флэнджер — частота Гц и глубина (0…1)
  void setFx(int unit, DjFx type, DjFxTarget target, double mix, double p1, double p2) =>
      _api.setFx(_h, unit, type.index, target.index, mix, p1, p2);

  /// Пики: дека A, дека B, выход (0…1+)
  late final ffi.Pointer<ffi.Float> _meters = malloc<ffi.Float>(3);
  List<double> meters() {
    _api.meters(_h, _meters);
    return [_meters[0], _meters[1], _meters[2]];
  }

  /// Форма волны загруженного трека: [buckets] значений 0…255
  Uint8List overview(int deck, int buckets) {
    final out = malloc<ffi.Uint8>(buckets);
    try {
      final n = _api.overview(_h, deck, buckets, out);
      return Uint8List.fromList(out.asTypedList(n));
    } finally {
      malloc.free(out);
    }
  }
}

// ---------- привязки к C-функциям ----------

typedef _CreateC = ffi.Pointer<ffi.Void> Function(ffi.Int32, ffi.Int32);
typedef _Create = ffi.Pointer<ffi.Void> Function(int, int);
typedef _HC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _H = void Function(ffi.Pointer<ffi.Void>);
typedef _IntHC = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _IntH = int Function(ffi.Pointer<ffi.Void>);
typedef _LoadC = ffi.Int64 Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Pointer<Utf8>);
typedef _Load = int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<Utf8>);
typedef _DeckC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _Deck = void Function(ffi.Pointer<ffi.Void>, int);
typedef _DeckIntC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _DeckInt = void Function(ffi.Pointer<ffi.Void>, int, int);
typedef _DeckIsC = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _DeckIs = int Function(ffi.Pointer<ffi.Void>, int);
typedef _DeckDoubleC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Double);
typedef _DeckDouble = void Function(ffi.Pointer<ffi.Void>, int, double);
typedef _DeckFloatC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float);
typedef _DeckFloat = void Function(ffi.Pointer<ffi.Void>, int, double);
typedef _PosC = ffi.Double Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _Pos = double Function(ffi.Pointer<ffi.Void>, int);
typedef _LenC = ffi.Int64 Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _Len = int Function(ffi.Pointer<ffi.Void>, int);
typedef _EqC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float, ffi.Float, ffi.Float);
typedef _Eq = void Function(ffi.Pointer<ffi.Void>, int, double, double, double);
typedef _LoopC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Double, ffi.Double, ffi.Int32);
typedef _Loop = void Function(ffi.Pointer<ffi.Void>, int, double, double, int);
typedef _XfC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Float, ffi.Int32);
typedef _Xf = void Function(ffi.Pointer<ffi.Void>, double, int);
typedef _FloatC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Float);
typedef _Float = void Function(ffi.Pointer<ffi.Void>, double);
typedef _FxC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32, ffi.Int32, ffi.Float, ffi.Float, ffi.Float);
typedef _Fx = void Function(ffi.Pointer<ffi.Void>, int, int, int, double, double, double);
typedef _MetersC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>);
typedef _Meters = void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>);
typedef _OverC = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32, ffi.Pointer<ffi.Uint8>);
typedef _Over = int Function(ffi.Pointer<ffi.Void>, int, int, ffi.Pointer<ffi.Uint8>);

class _Api {
  final ffi.DynamicLibrary l;
  _Api(this.l);

  late final create = l.lookupFunction<_CreateC, _Create>('dj_create');
  late final deviceStart = l.lookupFunction<_IntHC, _IntH>('dj_device_start');
  late final deviceStop = l.lookupFunction<_HC, _H>('dj_device_stop');
  late final destroy = l.lookupFunction<_HC, _H>('dj_destroy');
  late final load = l.lookupFunction<_LoadC, _Load>('dj_load');
  late final unload = l.lookupFunction<_DeckC, _Deck>('dj_unload');
  late final play = l.lookupFunction<_DeckIntC, _DeckInt>('dj_play');
  late final isPlaying = l.lookupFunction<_DeckIsC, _DeckIs>('dj_is_playing');
  late final seek = l.lookupFunction<_DeckDoubleC, _DeckDouble>('dj_seek');
  late final pos = l.lookupFunction<_PosC, _Pos>('dj_pos');
  late final length = l.lookupFunction<_LenC, _Len>('dj_length');
  late final setTempo = l.lookupFunction<_DeckDoubleC, _DeckDouble>('dj_set_tempo');
  late final setKeylock = l.lookupFunction<_DeckIntC, _DeckInt>('dj_set_keylock');
  late final setPitch = l.lookupFunction<_DeckFloatC, _DeckFloat>('dj_set_pitch');
  late final setTrim = l.lookupFunction<_DeckFloatC, _DeckFloat>('dj_set_trim');
  late final setFader = l.lookupFunction<_DeckFloatC, _DeckFloat>('dj_set_fader');
  late final setEq = l.lookupFunction<_EqC, _Eq>('dj_set_eq');
  late final setFilter = l.lookupFunction<_DeckFloatC, _DeckFloat>('dj_set_filter');
  late final setLoop = l.lookupFunction<_LoopC, _Loop>('dj_set_loop');
  late final setCrossfader = l.lookupFunction<_XfC, _Xf>('dj_set_crossfader');
  late final setMaster = l.lookupFunction<_FloatC, _Float>('dj_set_master');
  late final setFx = l.lookupFunction<_FxC, _Fx>('dj_set_fx');
  late final meters = l.lookupFunction<_MetersC, _Meters>('dj_meters');
  late final overview = l.lookupFunction<_OverC, _Over>('dj_overview');
}
