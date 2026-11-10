import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:djengine/djengine.dart';
import 'package:flutter/foundation.dart';

import 'audio_cache.dart';
import 'automix.dart';
import 'dj.dart';
import 'djsync.dart';
import 'dl/tools.dart';
import 'log.dart';
import 'models.dart';
import 'store.dart';

// DJ-пульт: две деки, микшер и эффекты поверх собственного движка (packages/djengine).
// Здесь вся «логика диджея» — загрузка треков, SYNC по долям, метки, петли, а также автоматический режим
// в духе autodj: сам выбирает следующий трек, подгоняет темп и тональность и сводит со случайным приёмом.

/// Состояние одной деки. Меняется только через [DjDecks]
class Deck {
  final int id;
  Deck(this.id);

  Track? track;
  MixProfile? profile;
  BeatGrid? grid;
  bool loading = false;
  String status = '';
  int frames = 0;
  Uint8List wave = Uint8List(0);
  bool playing = false;

  /// Темп (1,0 — как записано), диапазон ползунка в процентах, сохранение тональности, сдвиг тональности в полутонах
  double tempo = 1.0;
  double range = 16;
  bool keylock = true;
  double pitch = 0;

  /// Следовать за темпом и долями второй деки
  bool synced = false;

  /// Главная метка и четыре быстрые метки, мс
  int? cueMs;
  final List<int?> hot = List.filled(4, null);

  /// Петля, мс; [loopBeats] — её длина в долях
  double? loopIn, loopOut;
  bool loopOn = false;
  double loopBeats = 4;

  /// Положения регуляторов: подрезка в дБ, фейдер 0…1, эквалайзер и фильтр −1…1
  double trim = 0;
  double fader = 1;
  double eqLow = 0, eqMid = 0, eqHigh = 0;
  double filter = 0;

  int token = 0; // у каждой загрузки свой номер: устаревшая ничего не портит
  bool ready = false; // загружена и разобрана (для автоматического режима)

  double get lengthMs => frames / DjEngine.sampleRate * 1000;
  double? get bpm => profile?.bpm;

  /// Темп с учётом ползунка, уд/мин
  double? get effectiveBpm => bpm == null ? null : bpm! * tempo;

  /// Тональность Camelot с учётом сдвига
  Camelot? get key {
    final k = Camelot.parse(profile?.key);
    if (k == null) return null;
    return pitch.round() == 0 ? k : shiftKey(k, pitch.round());
  }
}

/// Настройки одного блока эффектов
class FxSlot {
  DjFx type = DjFx.none;
  DjFxTarget target = DjFxTarget.master;
  double mix = 0.35, p1 = 375, p2 = 0.45;

  static (double, double) defaultsFor(DjFx t) => switch (t) {
        DjFx.echo => (375, 0.45),
        DjFx.reverb => (0.6, 0.4),
        DjFx.flanger => (0.4, 0.6),
        DjFx.none => (0, 0),
      };
}

enum _Style { fade, bass, filter, echo }

enum _Phase { idle, transitioning }

class DjDecks extends ChangeNotifier {
  final Directory dir;
  final Tools tools;
  final AudioCache cache;
  final MixAnalyzer mixer;
  final Settings settings;
  final void Function() saveSettings;

  /// Из чего АвтоDJ выбирает следующий трек, и что он знает о треке
  final List<Track> Function() pool;
  final DjSong Function(Track) songOf;

  /// Остановить основной плеер, когда пульт начинает играть (иначе звук пойдёт из двух мест)
  final void Function() pauseMain;
  final Track? Function() mainTrack;

  DjDecks({
    required this.dir,
    required this.tools,
    required this.cache,
    required this.mixer,
    required this.settings,
    required this.saveSettings,
    required this.pool,
    required this.songOf,
    required this.pauseMain,
    required this.mainTrack,
  });

  final List<Deck> decks = [Deck(0), Deck(1)];
  final List<FxSlot> fx = [FxSlot(), FxSlot()];

  DjEngine? _e;
  String? error;
  bool get ready => _e != null;

  /// Тикает ~25 раз в секунду: позиции и индикаторы уровня обновляются через него, а не через notifyListeners
  final ValueNotifier<int> tick = ValueNotifier(0);
  List<double> levels = [0, 0, 0];

  double crossfader = 0; // −1 … 1
  bool sharpCurve = false;
  double master = 0.9;

  Timer? _timer;
  final Stopwatch _clock = Stopwatch();
  int _lastTickMs = 0;
  int _n = 0;

  // ---------- движок ----------

  /// Открывает движок и звуковое устройство; false — не вышло (причина в [error])
  bool ensureEngine() {
    if (_e != null) return true;
    final e = DjEngine.open();
    if (e == null) {
      error = 'Не удалось запустить звуковой движок (djengine.dll). Переустановите программу или обновите её.';
      notifyListeners();
      return false;
    }
    _e = e;
    error = null;
    e.setMaster(master);
    e.setCrossfader(crossfader, sharp: sharpCurve);
    for (final d in decks) {
      _applyAll(d);
    }
    _clock.start();
    _timer = Timer.periodic(const Duration(milliseconds: 40), (_) => _onTick());
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cuesTimer?.cancel();
    _flushCues();
    _e?.dispose();
    _e = null;
    tick.dispose();
    super.dispose();
  }

  void _applyAll(Deck d) {
    final e = _e;
    if (e == null) return;
    e.setTempo(d.id, d.tempo);
    e.setKeylock(d.id, d.keylock);
    e.setPitch(d.id, d.pitch);
    e.setTrim(d.id, d.trim);
    e.setFader(d.id, d.fader);
    _applyEq(d);
    e.setFilter(d.id, d.filter);
  }

  void _applyEq(Deck d) => _e?.setEq(d.id, eqKnobToDb(d.eqLow), eqKnobToDb(d.eqMid), eqKnobToDb(d.eqHigh));

  double posMs(int d) => _e == null ? 0 : _e!.pos(d) / DjEngine.sampleRate * 1000;
  double _frames(double ms) => ms * DjEngine.sampleRate / 1000;

  // ---------- загрузка треков ----------

  File _rawFor(String id) => File('${dir.path}${Platform.pathSeparator}$id.f32');

  /// Загружает [t] в деку [d]. [autoplay] — сразу играть
  Future<void> load(int d, Track t, {bool autoplay = false}) async {
    if (!ensureEngine()) return;
    final dk = decks[d];
    final token = ++dk.token;
    _e!.play(d, false);
    _e!.unload(d);
    _resetDeck(dk);
    dk
      ..track = t
      ..loading = true
      ..status = 'Скачиваю…';
    notifyListeners();
    try {
      final src = cache.fileFor(t.id);
      if (!(cache.has(t.id) && src.existsSync())) {
        cache.enqueue(t.id, front: true);
        var waited = 0;
        while (!(cache.has(t.id) && src.existsSync())) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (dk.token != token) return;
          waited += 400;
          if (waited > 180000) throw 'трек не скачался';
        }
      }
      dk.status = 'Готовлю звук…';
      notifyListeners();
      final raw = await _decode(t.id, src);
      if (dk.token != token) return;
      final frames = _e!.load(d, raw.path);
      if (frames <= 0) throw 'не открылся ($frames)';
      dk
        ..frames = frames
        ..wave = _e!.overview(d, 900)
        ..loading = false
        ..status = '';
      _loadCues(dk);
      _setProfile(dk, mixer.profile(t.id));
      _applyAll(dk);
      if (dk.profile == null || dk.profile!.v < MixProfile.version || dk.profile!.bpm == null) mixer.prepare(t.id);
      dk.ready = true;
      if (autoplay) _play(d, true);
      notifyListeners();
      unawaited(_prune());
    } catch (e) {
      if (dk.token != token) return;
      AppLog.warn('DJ-пульт: не загрузился трек', e);
      dk
        ..loading = false
        ..frames = 0
        ..status = 'Ошибка: $e';
      notifyListeners();
    }
  }

  Future<File> _decode(String id, File src) async {
    final out = _rawFor(id);
    if (out.existsSync() && out.lengthSync() > 0) {
      try {
        out.setLastModifiedSync(DateTime.now());
      } catch (_) {}
      return out;
    }
    if (!tools.ffmpeg.existsSync()) {
      await tools.ensure((_) {});
      if (!tools.ffmpeg.existsSync()) throw 'нет FFmpeg';
    }
    await dir.create(recursive: true);
    final part = File('${out.path}.part');
    await Tools.run(tools.ffmpeg.path, ['-y', '-v', 'error', '-i', src.path, '-f', 'f32le', '-ac', '2', '-ar', '${DjEngine.sampleRate}', part.path]);
    if (!part.existsSync() || part.lengthSync() == 0) throw 'ffmpeg не смог разобрать файл';
    await part.rename(out.path);
    return out;
  }

  /// Хранит несколько последних разобранных треков; остальное удаляет
  Future<void> _prune() async {
    try {
      final loaded = {for (final d in decks) if (d.track != null) d.track!.id};
      final files = <(File, DateTime)>[];
      await for (final f in dir.list()) {
        if (f is File && f.path.endsWith('.f32')) files.add((f, await f.lastModified()));
      }
      files.sort((a, b) => b.$2.compareTo(a.$2));
      for (var i = 8; i < files.length; i++) {
        final name = files[i].$1.uri.pathSegments.last;
        if (loaded.contains(name.substring(0, name.length - 4))) continue;
        await files[i].$1.delete();
      }
    } catch (_) {}
  }

  void _setProfile(Deck d, MixProfile? p) {
    d.profile = p;
    d.grid = gridOf(p);
  }

  /// Сетка долей из профиля. Если известны и начало, и хвост — темп уточняется по ним (мелкая ошибка темпа к концу трека растёт)
  static BeatGrid? gridOf(MixProfile? p) {
    if (p == null || p.bpm == null || p.bpm! <= 0) return null;
    final anchor = p.headBarMs ?? p.headBeatMs;
    if (anchor == null) return null;
    var bpm = p.bpm!;
    final tail = p.tailBeatMs;
    if (tail != null && tail - anchor > 20000) {
      final exact = (tail - anchor) / (60000.0 / bpm);
      final beats = exact.round();
      // Верим, только если число долей получилось почти целым: иначе тайминг хвоста не подходит к этому темпу
      if (beats > 8 && (exact - beats).abs() < 0.35) bpm = 60000.0 * beats / (tail - anchor);
    }
    return BeatGrid(bpm, anchor.toDouble(), barKnown: p.headBarMs != null);
  }

  void _resetDeck(Deck d) {
    d
      ..track = null
      ..profile = null
      ..grid = null
      ..frames = 0
      ..wave = Uint8List(0)
      ..playing = false
      ..tempo = 1.0
      ..pitch = 0
      ..synced = false
      ..cueMs = null
      ..loopIn = null
      ..loopOut = null
      ..loopOn = false
      ..eqLow = 0
      ..eqMid = 0
      ..eqHigh = 0
      ..filter = 0
      ..ready = false;
    for (var i = 0; i < 4; i++) {
      d.hot[i] = null;
    }
  }

  void eject(int d) {
    final dk = decks[d];
    dk.token++;
    _e?.play(d, false);
    _e?.unload(d);
    _resetDeck(dk);
    dk
      ..loading = false
      ..status = '';
    _applyAll(dk);
    notifyListeners();
  }

  // ---------- транспорт ----------

  void _play(int d, bool on) {
    final dk = decks[d];
    if (dk.frames == 0) return;
    if (on) pauseMain();
    _e?.play(d, on);
    dk.playing = on;
  }

  void playPause(int d) {
    final dk = decks[d];
    if (dk.frames == 0 || _e == null) return;
    final on = !_e!.isPlaying(d);
    // Дошли до конца — с начала
    if (on && posMs(d) >= dk.lengthMs - 50) _e!.seek(d, 0);
    _play(d, on);
    notifyListeners();
  }

  /// Метка (как на CDJ): на ходу — вернуться к метке и встать на паузу; на паузе — поставить метку здесь
  void cue(int d) {
    final dk = decks[d];
    if (dk.frames == 0 || _e == null) return;
    if (_e!.isPlaying(d)) {
      _play(d, false);
      _e!.seek(d, _frames((dk.cueMs ?? 0).toDouble()));
    } else if (dk.cueMs != null && (posMs(d) - dk.cueMs!).abs() > 30) {
      _e!.seek(d, _frames(dk.cueMs!.toDouble()));
    } else {
      dk.cueMs = _snapMs(dk, posMs(d)).round();
      _saveCues(dk);
    }
    notifyListeners();
  }

  /// Метка и проигрывание, пока кнопка зажата
  void cuePreview(int d, bool down) {
    final dk = decks[d];
    if (dk.frames == 0 || _e == null) return;
    if (down) {
      if (_e!.isPlaying(d)) {
        cue(d);
        return;
      }
      if (dk.cueMs == null || (posMs(d) - dk.cueMs!).abs() > 30) {
        cue(d);
        return;
      }
      _play(d, true);
    } else if (_e!.isPlaying(d) && dk.cueMs != null) {
      _play(d, false);
      _e!.seek(d, _frames(dk.cueMs!.toDouble()));
    }
    notifyListeners();
  }

  double _snapMs(Deck d, double ms) => d.grid == null ? ms : d.grid!.snap(ms).clamp(0, d.lengthMs).toDouble();

  void seekMs(int d, double ms) {
    final dk = decks[d];
    if (dk.frames == 0) return;
    _e?.seek(d, _frames(ms.clamp(0, dk.lengthMs).toDouble()));
  }

  void seekFraction(int d, double f) => seekMs(d, decks[d].lengthMs * f.clamp(0, 1));

  /// Сдвиг на [beats] долей (или [ms], если сетки нет)
  void jump(int d, double beats) {
    final dk = decks[d];
    final cur = posMs(d);
    seekMs(d, dk.grid != null ? dk.grid!.shiftBeats(cur, beats) : cur + beats * 500);
  }

  // ---------- метки и петли ----------

  void hotcue(int d, int i) {
    final dk = decks[d];
    if (dk.frames == 0 || _e == null) return;
    final at = dk.hot[i];
    if (at == null) {
      dk.hot[i] = _snapMs(dk, posMs(d)).round();
      _saveCues(dk);
    } else {
      _e!.seek(d, _frames(at.toDouble()));
      if (!_e!.isPlaying(d)) _play(d, true);
    }
    notifyListeners();
  }

  void clearHotcue(int d, int i) {
    final dk = decks[d];
    if (dk.hot[i] == null) return;
    dk.hot[i] = null;
    _saveCues(dk);
    notifyListeners();
  }

  /// Петля в [beats] долей от текущего места; повторное нажатие с тем же размером выключает
  void loop(int d, double beats) {
    final dk = decks[d];
    if (dk.frames == 0 || _e == null) return;
    if (dk.loopOn && dk.loopBeats == beats) {
      loopOff(d);
      return;
    }
    final start = dk.loopOn && dk.loopIn != null ? dk.loopIn! : posMs(d);
    final (a, b) = loopSpan(dk.grid, start, beats);
    dk.loopBeats = beats;
    dk.loopIn = a;
    dk.loopOut = math.min(b, dk.lengthMs);
    dk.loopOn = true;
    _e!.setLoop(d, _frames(a), _frames(dk.loopOut!), true);
    notifyListeners();
  }

  void loopOff(int d) {
    final dk = decks[d];
    dk.loopOn = false;
    if (dk.loopIn != null && dk.loopOut != null) _e?.setLoop(d, _frames(dk.loopIn!), _frames(dk.loopOut!), false);
    notifyListeners();
  }

  /// Вдвое короче или длиннее
  void loopScale(int d, double factor) {
    final dk = decks[d];
    if (!dk.loopOn) return;
    loop(d, (dk.loopBeats * factor).clamp(0.125, 64).toDouble());
  }

  /// Своя петля: «вход» здесь
  void loopIn(int d) {
    final dk = decks[d];
    dk.loopIn = _snapMs(dk, posMs(d));
    dk.loopOut = null;
    dk.loopOn = false;
    notifyListeners();
  }

  /// Своя петля: «выход» здесь, петля включается
  void loopOut(int d) {
    final dk = decks[d];
    final a = dk.loopIn;
    if (a == null || _e == null) return;
    final b = _snapMs(dk, posMs(d));
    if (b - a < 20) return;
    dk.loopOut = b;
    dk.loopBeats = dk.grid == null ? 0 : (b - a) / dk.grid!.periodMs;
    dk.loopOn = true;
    _e!.setLoop(d, _frames(a), _frames(b), true);
    notifyListeners();
  }

  // ---------- темп, тональность, SYNC ----------

  void setTempo(int d, double ratio) {
    final dk = decks[d];
    dk.tempo = ratio.clamp(0.5, 2.0).toDouble();
    _e?.setTempo(d, dk.tempo);
    notifyListeners();
  }

  /// Ползунок темпа: −1…1 в пределах [Deck.range] процентов
  void setTempoSlider(int d, double v) {
    final dk = decks[d];
    dk.synced = false;
    setTempo(d, 1 + v.clamp(-1, 1) * dk.range / 100);
  }

  double tempoSlider(int d) {
    final dk = decks[d];
    return ((dk.tempo - 1) * 100 / dk.range).clamp(-1, 1).toDouble();
  }

  void setRange(int d, double pct) {
    decks[d].range = pct;
    notifyListeners();
  }

  void setKeylock(int d, bool on) {
    decks[d].keylock = on;
    _e?.setKeylock(d, on);
    notifyListeners();
  }

  void setPitch(int d, double semitones) {
    decks[d].pitch = semitones.clamp(-12, 12).toDouble();
    _e?.setPitch(d, decks[d].pitch);
    notifyListeners();
  }

  /// Временно чуть ускорить или замедлить деку (подтолкнуть пластинку): [dir] −1, 0 или 1
  double _bend = 0;
  int _bendDeck = -1;
  void bend(int d, int dir) {
    final dk = decks[d];
    if (dir == 0) {
      _bend = 0;
      _bendDeck = -1;
      _e?.setTempo(d, dk.tempo);
    } else {
      _bend = dir * 0.05;
      _bendDeck = d;
      _e?.setTempo(d, dk.tempo * (1 + _bend));
    }
  }

  /// Подогнать деку [d] под вторую: темп и доли. [lock] — потом следовать за ней
  bool sync(int d, {bool lock = true}) {
    final s = decks[d], m = decks[1 - d];
    final sg = s.grid, mg = m.grid;
    if (sg == null || mg == null) return false;
    final mBpm = mg.bpm * m.tempo;
    final r = syncRatio(mBpm, sg.bpm);
    setTempo(d, r.ratio);
    s.synced = lock;
    if (m.playing || s.playing) {
      final shift = phaseShiftMs(mg, posMs(1 - d), sg, posMs(d), r.k);
      if (shift.abs() > 1) seekMs(d, posMs(d) + shift);
    }
    notifyListeners();
    return true;
  }

  void unsync(int d) {
    decks[d].synced = false;
    notifyListeners();
  }

  // ---------- микшер ----------

  void setCrossfader(double x) {
    crossfader = x.clamp(-1, 1).toDouble();
    _e?.setCrossfader(crossfader, sharp: sharpCurve);
    notifyListeners();
  }

  void setSharpCurve(bool v) {
    sharpCurve = v;
    _e?.setCrossfader(crossfader, sharp: v);
    notifyListeners();
  }

  void setMaster(double g) {
    master = g.clamp(0, 1.5).toDouble();
    _e?.setMaster(master);
  }

  void setTrim(int d, double db) {
    decks[d].trim = db.clamp(-12, 12).toDouble();
    _e?.setTrim(d, decks[d].trim);
  }

  void setFader(int d, double v) {
    decks[d].fader = v.clamp(0, 1).toDouble();
    _e?.setFader(d, decks[d].fader);
  }

  void setEq(int d, {double? low, double? mid, double? high}) {
    final dk = decks[d];
    if (low != null) dk.eqLow = low.clamp(-1, 1).toDouble();
    if (mid != null) dk.eqMid = mid.clamp(-1, 1).toDouble();
    if (high != null) dk.eqHigh = high.clamp(-1, 1).toDouble();
    _applyEq(dk);
  }

  /// Фильтр: влево — убирает верха, вправо — низы
  void setFilter(int d, double v) {
    decks[d].filter = v.clamp(-1, 1).toDouble();
    _e?.setFilter(d, decks[d].filter);
  }

  void setFx(int unit, {DjFx? type, DjFxTarget? target, double? mix, double? p1, double? p2}) {
    final f = fx[unit];
    if (type != null && type != f.type) {
      f.type = type;
      final (a, b) = FxSlot.defaultsFor(type);
      f.p1 = a;
      f.p2 = b;
    }
    if (target != null) f.target = target;
    if (mix != null) f.mix = mix.clamp(0, 1).toDouble();
    if (p1 != null) f.p1 = p1;
    if (p2 != null) f.p2 = p2;
    _pushFx(unit);
    notifyListeners();
  }

  void _pushFx(int unit) {
    final f = fx[unit];
    _e?.setFx(unit, f.type, f.type == DjFx.none ? DjFxTarget.off : f.target, f.mix, f.p1, f.p2);
  }

  // ---------- метки треков на диске ----------

  Map<String, dynamic>? _cues;
  Timer? _cuesTimer;
  File get _cuesFile => File('${dir.path}${Platform.pathSeparator}dj_cues.json');

  Map<String, dynamic> _cueBook() {
    if (_cues != null) return _cues!;
    try {
      if (_cuesFile.existsSync()) {
        final j = jsonDecode(_cuesFile.readAsStringSync());
        if (j is Map<String, dynamic>) return _cues = j;
      }
    } catch (_) {}
    return _cues = {};
  }

  void _loadCues(Deck d) {
    final j = _cueBook()[d.track?.id];
    if (j is! Map) return;
    d.cueMs = (j['c'] as num?)?.toInt();
    final h = j['h'];
    if (h is List) {
      for (var i = 0; i < 4 && i < h.length; i++) {
        d.hot[i] = (h[i] as num?)?.toInt();
      }
    }
  }

  void _saveCues(Deck d) {
    final id = d.track?.id;
    if (id == null) return;
    final book = _cueBook();
    if (d.cueMs == null && d.hot.every((e) => e == null)) {
      book.remove(id);
    } else {
      book[id] = {'c': d.cueMs, 'h': d.hot};
    }
    _cuesTimer?.cancel();
    _cuesTimer = Timer(const Duration(milliseconds: 800), _flushCues);
  }

  void _flushCues() {
    try {
      if (_cues == null) return;
      dir.createSync(recursive: true);
      _cuesFile.writeAsStringSync(jsonEncode(_cues));
    } catch (e) {
      AppLog.warn('DJ-пульт: не сохранились метки', e);
    }
  }

  // ---------- тик: позиции, уровни, SYNC-замок, АвтоDJ ----------

  void _onTick() {
    final e = _e;
    if (e == null) return;
    final now = _clock.elapsedMilliseconds;
    final dt = (now - _lastTickMs).clamp(1, 200) / 1000.0;
    _lastTickMs = now;
    _n++;

    var changed = false;
    for (final d in decks) {
      if (d.frames == 0) continue;
      final p = e.isPlaying(d.id);
      if (p != d.playing) {
        d.playing = p;
        changed = true;
      }
    }

    // Профиль может досчитаться позже, чем трек загрузился
    if (_n % 25 == 0) {
      for (final d in decks) {
        final t = d.track;
        if (t == null || d.frames == 0) continue;
        if (d.profile == null || d.profile!.bpm == null || d.profile!.v < MixProfile.version) {
          final p = mixer.profile(t.id);
          if (p != null && !identical(p, d.profile)) {
            _setProfile(d, p);
            changed = true;
          }
        }
      }
    }

    _followSync();
    _tempoReturn(dt);
    if (auto) _autoStep(dt);

    levels = e.meters();
    tick.value++;
    if (changed) notifyListeners();
  }

  /// SYNC-замок: ведомая дека держит темп ведущей, а расхождение по фазе гасится лёгкой подгонкой скорости
  void _followSync() {
    final e = _e!;
    for (final s in decks) {
      if (!s.synced) continue;
      final m = decks[1 - s.id];
      final sg = s.grid, mg = m.grid;
      if (sg == null || mg == null || s.frames == 0 || m.frames == 0) continue;
      final r = syncRatio(mg.bpm * m.tempo, sg.bpm);
      if ((r.ratio - s.tempo).abs() > 0.0002) {
        s.tempo = r.ratio.clamp(0.5, 2.0).toDouble();
      }
      var rate = s.tempo;
      if (s.playing && m.playing && s.id != _bendDeck) {
        final err = phaseError(mg, posMs(m.id), sg, posMs(s.id), r.k);
        rate = s.tempo * (1 + (-err * 0.08).clamp(-0.015, 0.015));
      }
      e.setTempo(s.id, s.id == _bendDeck ? rate * (1 + _bend) : rate);
    }
  }

  // ---------- АвтоDJ ----------

  bool auto = false;
  String autoStatus = '';
  int _live = -1;
  _Phase _phase = _Phase.idle;
  bool _busy = false;
  final Map<String, DateTime> _recent = {};
  int _failures = 0;

  // переход
  int _trIn = 0;
  double _trElapsed = 0, _trDur = 8000;
  _Style _trStyle = _Style.fade;
  double _trFrom = -1, _trTo = 1;

  bool _opt(String k, bool def) => settings.viewOf(k, def ? '1' : '0') == '1';

  /// Как сводить: 'random' или конкретный приём
  String get autoStyle => settings.viewOf('dj.auto.style', 'random');
  int get autoBars => settings.viewNum('dj.auto.bars', 8).round();
  bool get autoKeyMatch => _opt('dj.auto.key', true);
  double get autoMaxBpm => settings.viewNum('dj.auto.maxbpm', 10).clamp(2, 25).toDouble();
  bool get autoRestoreTempo => _opt('dj.auto.restore', true);

  void putSetting(String k, String v) {
    settings.view[k] = v;
    saveSettings();
    notifyListeners();
  }

  Future<void> setAuto(bool on) async {
    if (on == auto) return;
    if (on && !ensureEngine()) return;
    auto = on;
    _phase = _Phase.idle;
    _failures = 0;
    autoStatus = '';
    if (on) {
      final a = decks[0], b = decks[1];
      if (a.frames > 0 && (a.playing || b.frames == 0)) {
        _live = 0;
      } else if (b.frames > 0) {
        _live = 1;
      } else {
        _live = -1;
      }
    }
    notifyListeners();
  }

  /// Дека, на которой сейчас звучит АвтоDJ (−1 — пока никакой)
  int get liveDeck => _live;

  DjOptions get _djOptions => DjOptions(maxBpmAdjust: autoMaxBpm / 100, harmonic: !autoKeyMatch);

  void _autoStep(double dt) {
    if (_phase == _Phase.transitioning) {
      _transitionStep(dt);
      return;
    }
    if (_busy) return;
    if (_live < 0 || decks[_live].frames == 0) {
      if (!decks[0].loading && !decks[1].loading) unawaited(_autoStart());
      return;
    }
    final l = decks[_live], o = decks[1 - _live];
    // Основная дека закончила играть сама: следующая — сразу
    final ended = !l.playing && l.frames > 0 && posMs(l.id) >= l.lengthMs - 80;
    if (o.frames == 0 && !o.loading) {
      if (l.playing || ended) unawaited(_prepareNext());
      return;
    }
    if (!o.ready || o.loading) {
      autoStatus = 'Готовлю следующий трек…';
      if (ended) _beginTransition(0);
      return;
    }
    if (!l.playing && !ended) {
      autoStatus = 'Пауза';
      return;
    }
    if (ended) {
      _beginTransition(0);
      return;
    }
    final exit = _exitMs(l);
    final left = exit - posMs(l.id);
    autoStatus = left > 0 ? 'Следующий переход через ${(left / 1000).round()} с' : 'Переход…';
    if (left <= 0) _beginTransition(_trLenMs(l));
  }

  Future<void> _autoStart() async {
    if (_busy) return;
    _busy = true;
    try {
      final list = pool();
      if (list.isEmpty) {
        autoStatus = 'Нет треков для выбора';
        return;
      }
      final t = mainTrack() ?? list[math.Random().nextInt(list.length)];
      autoStatus = 'Загружаю первый трек…';
      await load(0, t, autoplay: false);
      if (!auto) return;
      if (decks[0].frames == 0) {
        _failures++;
        if (_failures > 5) await setAuto(false);
        return;
      }
      _live = 0;
      _pickBars();
      crossfader = -1;
      _e?.setCrossfader(-1, sharp: sharpCurve);
      _enterAt(decks[0]);
      _play(0, true);
      _recent[t.id] = DateTime.now();
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  /// Ставит деку на точку входа: главная метка, иначе первая доля такта после вступления
  void _enterAt(Deck d) {
    final ms = _entryMs(d);
    if (ms > 0) _e?.seek(d.id, _frames(ms));
  }

  double _entryMs(Deck d) {
    if (d.cueMs != null) return d.cueMs!.toDouble();
    final p = d.profile;
    if (d.grid != null) return d.grid!.anchorMs;
    if (p != null) return p.introMs.toDouble();
    return 0;
  }

  /// Где начинать уход с [d]: четвёртая быстрая метка, иначе начало затихания, но так, чтобы переход закончился до тишины
  double _exitMs(Deck d) {
    final hot = d.hot[3];
    if (hot != null) return hot.toDouble();
    final p = d.profile;
    final len = d.lengthMs;
    final tr = _trLenMs(d);
    if (p == null) return len - tr - 3000;
    final end = (p.endMs > 0 && p.endMs <= len ? p.endMs : len).toDouble();
    final latest = end - tr;
    var start = p.outroMs > 0 ? p.outroMs.toDouble() : latest;
    start = start.clamp(latest - 15000, latest).toDouble();
    final g = d.grid;
    if (g != null) {
      final bar = g.barKnown ? 4.0 : 1.0;
      var s = g.nextBar(start);
      if (!g.barKnown) s = g.nextBeat(start);
      if (s > latest) s -= bar * g.periodMs;
      return s;
    }
    return start;
  }

  /// Длина ближайшего перехода в тактах: выбирается заранее, когда готовится следующий трек
  int _bars = 8;

  void _pickBars() {
    _bars = settings.viewOf('dj.auto.bars', '8') == 'rnd' ? const [4, 8, 16][math.Random().nextInt(3)] : autoBars.clamp(1, 64).toInt();
  }

  int _trLenMs(Deck d) => transitionMs(d.effectiveBpm, _bars);

  /// Выбирает и готовит следующий трек на свободной деке
  Future<void> _prepareNext() async {
    if (_busy) return;
    _busy = true;
    try {
      _pickBars();
      final l = decks[_live], o = decks[1 - _live];
      final list = pool();
      if (list.length < 2 && l.track != null) {
        autoStatus = 'Для АвтоDJ нужно хотя бы два трека';
        return;
      }
      final cur = l.track == null ? null : songOf(l.track!);
      final byId = {for (final t in list) t.id: t};
      DjSong? next;
      if (cur != null) {
        next = AutoDj.pickNext(cur, [for (final t in list) songOf(t)], recent: _recent, options: _djOptions);
      } else {
        next = list.isEmpty ? null : songOf(list[math.Random().nextInt(list.length)]);
      }
      final track = next == null ? null : byId[next.id];
      if (track == null) {
        autoStatus = 'Нечего играть дальше';
        return;
      }
      autoStatus = 'Загружаю: ${track.title}';
      notifyListeners();
      await load(o.id, track);
      if (!auto) return;
      if (o.frames == 0) {
        _failures++;
        if (_failures > 5) await setAuto(false);
        return;
      }
      _failures = 0;
      await _waitProfile(o, const Duration(seconds: 25));
      if (!auto || o.track?.id != track.id) return;
      _matchIncoming(l, o);
      _enterAt(o);
      o.ready = true;
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  Future<void> _waitProfile(Deck d, Duration max) async {
    final end = DateTime.now().add(max);
    final id = d.track?.id;
    while (id != null && d.track?.id == id && DateTime.now().isBefore(end)) {
      final p = mixer.profile(id);
      if (p != null && p.v >= MixProfile.version) {
        _setProfile(d, p);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Как в autodj: подгоняем следующий трек под играющий. Тональность — сдвигом на несколько полутонов, темп — SYNC
  void _matchIncoming(Deck l, Deck o) {
    o.pitch = 0;
    if (autoKeyMatch && o.keylock) {
      final s = keyShiftFor(l.key, Camelot.parse(o.profile?.key));
      if (s != 0) {
        o.pitch = s.toDouble();
        _e?.setPitch(o.id, o.pitch);
      }
    }
    final lg = l.grid, og = o.grid;
    if (lg != null && og != null) {
      final r = syncRatio(lg.bpm * l.tempo, og.bpm);
      if ((r.ratio - 1).abs() <= autoMaxBpm / 100) {
        o.tempo = r.ratio;
        _e?.setTempo(o.id, o.tempo);
        o.synced = true;
      }
    }
    _applyEq(o);
  }

  void _beginTransition(int durationMs) {
    final l = decks[_live], o = decks[1 - _live];
    _trIn = o.id;
    _trFrom = _live == 0 ? -1 : 1;
    _trTo = -_trFrom;
    final hasGrid = l.grid != null && o.grid != null;
    _trStyle = _pickStyle(hasGrid);
    // Резкий уход без доли — просто короткое наложение
    _trDur = durationMs <= 0 ? 800 : durationMs.toDouble();
    _trElapsed = 0;

    // Запускаем входящий трек так, чтобы доли встали на доли играющего
    if (hasGrid) {
      final r = syncRatio(l.grid!.bpm * l.tempo, o.grid!.bpm);
      final shift = phaseShiftMs(l.grid!, posMs(l.id), o.grid!, posMs(o.id), r.k);
      if (shift.abs() > 1) seekMs(o.id, posMs(o.id) + shift);
      o.synced = o.synced || (r.ratio - 1).abs() <= autoMaxBpm / 100;
    }
    if (_trStyle == _Style.bass) {
      o.eqLow = -1;
      _applyEq(o);
    }
    if (_trStyle == _Style.filter) {
      setFilter(o.id, -0.85);
    }
    if (_trStyle == _Style.echo) {
      final period = l.grid?.periodMs ?? 500;
      fx[0]
        ..type = DjFx.echo
        ..target = DjFxTarget.master
        ..mix = 0
        ..p1 = period * 0.75
        ..p2 = 0.5;
      _pushFx(0);
    }
    _play(o.id, true);
    _phase = _Phase.transitioning;
    autoStatus = 'Переход: ${_styleName(_trStyle)}';
    _recent[o.track!.id] = DateTime.now();
    notifyListeners();
  }

  static String _styleName(_Style s) => switch (s) {
        _Style.fade => 'плавное наложение',
        _Style.bass => 'смена басов',
        _Style.filter => 'фильтр',
        _Style.echo => 'эхо',
      };

  _Style _pickStyle(bool hasGrid) {
    switch (autoStyle) {
      case 'fade':
        return _Style.fade;
      case 'bass':
        return hasGrid ? _Style.bass : _Style.fade;
      case 'filter':
        return _Style.filter;
      case 'echo':
        return _Style.echo;
    }
    final all = [_Style.fade, if (hasGrid) _Style.bass, _Style.filter, _Style.echo];
    return all[math.Random().nextInt(all.length)];
  }

  static double _smooth(double a, double b, double x) {
    final t = ((x - a) / (b - a)).clamp(0.0, 1.0).toDouble();
    return t * t * (3 - 2 * t);
  }

  void _transitionStep(double dt) {
    final l = decks[1 - _trIn], o = decks[_trIn];
    _trElapsed += dt * 1000;
    final p = (_trElapsed / _trDur).clamp(0.0, 1.0).toDouble();
    double x;
    switch (_trStyle) {
      case _Style.fade:
        x = p;
      case _Style.bass:
        x = _smooth(0, 1, p);
        l.eqLow = -1 * _smooth(0.45, 0.55, p);
        o.eqLow = -1 * (1 - _smooth(0.45, 0.55, p));
        _applyEq(l);
        _applyEq(o);
      case _Style.filter:
        x = _smooth(0.1, 0.9, p);
        setFilter(l.id, 0.85 * _smooth(0.2, 1, p));
        setFilter(o.id, -0.85 * (1 - _smooth(0, 0.8, p)));
      case _Style.echo:
        x = _smooth(0.05, 0.6, p);
        final m = p < 0.5 ? 0.55 * _smooth(0, 0.5, p) : 0.55 * (1 - _smooth(0.5, 1, p));
        fx[0].mix = m;
        _pushFx(0);
    }
    crossfader = _trFrom + (_trTo - _trFrom) * x;
    _e?.setCrossfader(crossfader, sharp: sharpCurve);
    if (p >= 1) _finishTransition(l, o);
  }

  void _finishTransition(Deck l, Deck o) {
    _e?.setCrossfader(_trTo, sharp: sharpCurve);
    crossfader = _trTo;
    if (_trStyle == _Style.echo) {
      fx[0].type = DjFx.none;
      _pushFx(0);
    }
    o.eqLow = 0;
    o.eqMid = 0;
    o.eqHigh = 0;
    _applyEq(o);
    setFilter(o.id, 0);
    eject(l.id);
    // Следующая основная дека — бывшая входящая; её темп вернёт _tempoReturn
    o.synced = false;
    _live = o.id;
    _phase = _Phase.idle;
    autoStatus = '';
    notifyListeners();
  }

  /// После перехода трек, подогнанный под предыдущий, плавно возвращается к своему темпу
  void _tempoReturn(double dt) {
    if (!auto || !autoRestoreTempo || _phase != _Phase.idle || _live < 0) return;
    final d = decks[_live];
    if (d.synced || d.frames == 0 || (d.tempo - 1).abs() < 0.0005 || d.id == _bendDeck) return;
    final step = 0.002 * dt;
    final nt = d.tempo > 1 ? math.max(1.0, d.tempo - step) : math.min(1.0, d.tempo + step);
    d.tempo = nt;
    _e?.setTempo(d.id, nt);
  }

  /// Сдвинуть тональность следующей деки вручную, например перед сведением
  void keyMatchNow(int d) {
    final o = decks[1 - d], s = decks[d];
    final sh = keyShiftFor(o.key, Camelot.parse(s.profile?.key));
    setPitch(d, sh.toDouble());
  }
}
