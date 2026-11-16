import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'audio_cache.dart';
import 'beats.dart';
import 'dj.dart';
import 'dl/tools.dart';
import 'mixbook.dart';
import 'log.dart';

// Умный переход между треками (как «Automix» в Spotify). Готовых библиотек для Flutter нет,
// поэтому делаем сами: ffmpeg один раз переводит трек в тихую «огибающую» громкости,
// по ней находим, где в начале тишина, где в конце трек затихает и насколько он громкий.
// Переход начинается там, где песня на самом деле уходит, а не за N секунд до конца файла;
// следующий трек стартует без пустого вступления, громкость двух треков выравнивается,
// а длина перехода подгоняется под целое число тактов, если известен темп.
//
// Тот же разбор звука кормит АвтоDJ (как в Mixxx): темп, положение долей, тональность по кругу Camelot
// и форма волны для полосы перемотки. Темп, тональность и жанр, вписанные в теги файла, главнее собственного разбора.

/// Что известно о звуке трека
class MixProfile {
  /// Версия разбора. У профилей старше этой нет темпа, тональности и волны: их досчитаем, когда трек снова будет в кэше
  static const version = 3;

  final int durationMs;
  final int introMs; // где кончается тишина в начале
  final int outroMs; // откуда трек начинает затихать к концу
  final int endMs; // где начинается тишина в конце
  final double loudDb; // типичная громкость тела трека

  /// Версия разбора, которым получен профиль
  final int v;

  /// Темп (удары в минуту); null — не известен
  final double? bpm;

  /// Где стоит сильная доля после вступления и ближе к концу, мс. Только если сетку долей можно считать верной
  final int? headBeatMs;
  final int? tailBeatMs;

  /// Где начинается такт (первая доля) после вступления и ближе к концу, мс; null — не определили
  final int? headBarMs;
  final int? tailBarMs;

  /// Тональность в записи Camelot («8A»); null — не известна
  final String? key;

  /// Форма волны трека: [waveBuckets] значений 0…255; пусто — не посчитана
  final List<int> wave;

  /// Жанр из тегов файла (нижний регистр)
  final String genre;

  const MixProfile({
    required this.durationMs,
    required this.introMs,
    required this.outroMs,
    required this.endMs,
    required this.loudDb,
    this.v = 1,
    this.bpm,
    this.headBeatMs,
    this.tailBeatMs,
    this.headBarMs,
    this.tailBarMs,
    this.key,
    this.wave = const [],
    this.genre = '',
  });

  /// Профиль с темпом, тональностью, волной и жанром. [tagBpm], [tagKey] — что вписано в теги файла:
  /// им верим больше. Сетка долей остаётся, только если темп из тегов с найденным не спорит
  MixProfile withAnalysis(AudioAnalysis? a, {double? tagBpm, String? tagKey, String genre = ''}) {
    final detected = (a != null && a.bpm != null && a.bpmConfidence >= 0.1) ? a.bpm : null;
    final tag = (tagBpm != null && tagBpm >= 40 && tagBpm <= 250) ? tagBpm : null;
    double? bpmNow;
    int? head = a?.headBeatMs, tail = a?.tailBeatMs, headBar = a?.headBarMs, tailBar = a?.tailBarMs;
    if (tag != null) {
      bpmNow = tag;
      if (detected == null || bpmStretch(tag, detected) > 0.03) {
        head = null;
        tail = null;
        headBar = null;
        tailBar = null;
      } else {
        // Сетка долей построена по своему темпу, он точнее округлённого в теге: с ним доли не разойдутся
        bpmNow = detected;
      }
    } else if (detected != null) {
      bpmNow = detected;
    } else {
      head = null;
      tail = null;
      headBar = null;
      tailBar = null;
    }
    String? keyNow;
    final tk = Camelot.parse(tagKey);
    if (tk != null) {
      keyNow = tk.toString();
    } else if (a != null && a.key != null && a.keyConfidence >= 0.5) {
      keyNow = a.key;
    }
    return MixProfile(
      durationMs: durationMs,
      introMs: introMs,
      outroMs: outroMs,
      endMs: endMs,
      loudDb: loudDb,
      v: version,
      bpm: bpmNow,
      headBeatMs: head,
      tailBeatMs: tail,
      headBarMs: headBar,
      tailBarMs: tailBar,
      key: keyNow,
      wave: (a != null && a.wave.isNotEmpty) ? a.wave : wave,
      genre: genre.isNotEmpty ? genre : this.genre,
    );
  }

  Map<String, dynamic> toJson() => {
        'd': durationMs,
        'i': introMs,
        'o': outroMs,
        'e': endMs,
        'l': loudDb,
        if (v > 1) 'v': v,
        if (bpm != null) 'bpm': bpm,
        if (headBeatMs != null) 'hb': headBeatMs,
        if (tailBeatMs != null) 'tb': tailBeatMs,
        if (headBarMs != null) 'hB': headBarMs,
        if (tailBarMs != null) 'tB': tailBarMs,
        if (key != null) 'k': key,
        if (wave.isNotEmpty) 'w': base64Encode(Uint8List.fromList(wave)),
        if (genre.isNotEmpty) 'g': genre,
      };

  static MixProfile? fromJson(dynamic j) {
    if (j is! Map) return null;
    try {
      var wave = const <int>[];
      final w = j['w'];
      if (w is String && w.isNotEmpty) wave = base64Decode(w).toList();
      return MixProfile(
        durationMs: (j['d'] as num).toInt(),
        introMs: (j['i'] as num).toInt(),
        outroMs: (j['o'] as num).toInt(),
        endMs: (j['e'] as num).toInt(),
        loudDb: (j['l'] as num).toDouble(),
        v: (j['v'] as num?)?.toInt() ?? 1,
        bpm: (j['bpm'] as num?)?.toDouble(),
        headBeatMs: (j['hb'] as num?)?.toInt(),
        tailBeatMs: (j['tb'] as num?)?.toInt(),
        headBarMs: (j['hB'] as num?)?.toInt(),
        tailBarMs: (j['tB'] as num?)?.toInt(),
        key: j['k'] as String?,
        wave: wave,
        genre: (j['g'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// Огибающая: громкость в дБ на каждые [frameMs] миллисекунд
  static MixProfile? fromEnvelope(List<double> db, {int frameMs = 50}) {
    if (db.length < 40) return null;
    final peak = db.reduce(math.max);
    final silence = peak - 32; // тише этого — считаем тишиной
    var first = db.indexWhere((v) => v > silence);
    var last = db.lastIndexWhere((v) => v > silence);
    if (first < 0 || last <= first) return null;
    // Тело трека: середина, без вступления и концовки
    final body = db.sublist(first + (last - first) ~/ 5, last - (last - first) ~/ 5)..sort();
    final level = body.isEmpty ? peak - 10 : body[body.length ~/ 2];
    // Сглаживание в секунду — отдельные паузы между нотами не считаются концом
    final win = (1000 / frameMs).round();
    double avg(int i) {
      final a = math.max(first, i - win ~/ 2), b = math.min(last, i + win ~/ 2);
      var s = 0.0;
      for (var k = a; k <= b; k++) {
        s += db[k];
      }
      return s / (b - a + 1);
    }

    // Затихание: последний момент, когда трек ещё звучит почти в полную силу
    var outro = last;
    while (outro > first && avg(outro) < level - 5) {
      outro--;
    }
    return MixProfile(
      durationMs: db.length * frameMs,
      introMs: first * frameMs,
      outroMs: outro * frameMs,
      endMs: (last + 1) * frameMs,
      loudDb: level,
    );
  }
}

/// Как сделать переход между двумя треками
/// Настройки «диджейского» перехода: длина в тактах, насколько можно подтягивать темп, обмен басов
class DjMix {
  /// Длина перехода в тактах (по 4 доли)
  final int bars;

  /// Самая большая подгонка темпа следующего трека (0,08 — 8 %)
  final double range;

  /// Обмен басов: сначала у следующего трека срезаны низы, на середине перехода низы переходят к нему
  final bool bass;

  /// При несовместимых тональностях переход укорачивается до двух тактов: недолго терпеть разлад
  final bool harmonic;

  /// Сдвиг долей следующего трека вручную, мс: «+» — позже. Нужен, если на слух доли чуть расходятся
  final int offsetMs;

  final bool transpose;
  final int outgoingShift;
  const DjMix(
      {this.bars = 8,
      this.range = 0.08,
      this.bass = true,
      this.harmonic = true,
      this.offsetMs = 0,
      this.transpose = false,
      this.outgoingShift = 0});

  DjMix withOutgoingShift(int value) => DjMix(
      bars: bars,
      range: range,
      bass: bass,
      harmonic: harmonic,
      offsetMs: offsetMs,
      transpose: transpose,
      outgoingShift: value);
}

class MixPlan {
  /// Absolute pitch shifts relative to the recordings, not successive deltas.
  final int transpose, outgoingShift;
  final bool tempoRamp;
  final Duration start; // когда в уходящем треке начать
  final Duration length; // сколько длится
  final Duration inStart; // с какого места начать следующий
  final double inGain; // громкость следующего в начале перехода (выравнивание), к концу — 1

  /// Диджейский переход: доли двух треков совпадают, следующий играет с подогнанным темпом
  final bool dj;

  /// Во сколько раз ускорить (замедлить) следующий трек, чтобы его темп совпал с уходящим; после перехода темп плавно возвращается
  final double rate;

  /// Когда (от начала перехода) менять басы местами; null — без обмена
  final Duration? swapAt;

  /// Сетка долей для подстройки на лету: время какой-то доли и период уходящего ($1, $2) и следующего ($3, $4) трека, мс
  /// (время — по самому треку). null — сетки нет
  final (double, double, double, double)? grid;

  /// Сдвиг долей следующего трека, заданный вручную, мс
  final int offsetMs;

  /// За сколько до начала перехода запускать следующий трек (без звука), чтобы он успел «встать на рельсы»
  final Duration preroll;

  const MixPlan(this.start, this.length, this.inStart, this.inGain,
      {this.dj = false,
      this.rate = 1.0,
      this.swapAt,
      this.grid,
      this.offsetMs = 0,
      this.preroll = Duration.zero,
      this.transpose = 0,
      this.outgoingShift = 0,
      this.tempoRamp = false});

  /// [maxSec] — самый длинный переход (настройка), [bpm] — темп уходящего трека, если известен
  /// (свой разбор звука важнее, он в профиле). Если у обоих треков известна сетка долей и темпы близки,
  /// переход начинается на доле уходящего трека, а следующий входит на своей доле.
  /// С [dj] переход длится заданное число тактов, темп следующего подгоняется под уходящий (если разница в пределах
  /// [DjMix.range]); если для этого не хватает данных, переход обычный
  static MixPlan make(MixProfile out, MixProfile inn, {int maxSec = 8, double? bpm, DjMix? dj}) {
    if (dj != null) {
      final p = _makeDj(out, inn, dj);
      if (p != null) return p;
    }
    const minMs = 1500;
    final maxMs = math.max(minMs, maxSec * 1000);
    final tail = out.endMs;
    final tempo = out.bpm ?? bpm;
    // Переход занимает затихание, но не короче 1,5 с и не длиннее настройки
    var len = (tail - out.outroMs).clamp(minMs, maxMs).toInt();
    // Под такт: целое число тактов по 4 доли, если темп разумный
    if (tempo != null && tempo >= 60 && tempo <= 200) {
      final bar = 4 * 60000 / tempo;
      final bars = math.max(1, (len / bar).round());
      final fitted = (bars * bar).round();
      if (fitted <= maxMs + bar / 2) len = math.max(minMs, fitted);
    }
    var start = math.max(out.introMs + 10000, tail - len); // никогда не раньше, чем через 10 с после начала
    // Вступление следующего пропускаем, только тишину и не больше 8 с
    var inStart = math.min(inn.introMs, 8000);
    // По долям: сетка нужна у обоих, и темпы не должны сильно расходиться, иначе доли «поплывут» во время перехода
    final ob = out.bpm, ib = inn.bpm, oh = out.tailBeatMs, ih = inn.headBeatMs;
    if (ob != null && ib != null && oh != null && ih != null && bpmStretch(ob, ib) <= 0.03) {
      final snapped = snapToBeat(start, oh, ob, durationMs: tail - minMs);
      if (snapped >= out.introMs + 10000 - 100) start = snapped;
      var enter = snapToBeat(inStart, ih, ib, durationMs: 8000 + (60000 / ib).round());
      // Не раньше, чем кончится тишина: тогда берём следующую долю
      if (enter < inn.introMs) enter += (60000 / ib).round();
      if (enter >= 0 && enter <= 12000) inStart = enter;
    }
    final diff = (out.loudDb - inn.loudDb).clamp(-6.0, 6.0);
    return MixPlan(
      Duration(milliseconds: start),
      Duration(milliseconds: tail - start),
      Duration(milliseconds: inStart),
      math.pow(10, diff / 20).toDouble(),
    );
  }

  /// Переход, настроенный вручную. Что не задано ([TransitionPref.outMs], [TransitionPref.inMs]), берётся из автоматического
  /// плана [auto] (если он есть) или считается заново. Длина не выходит за конец уходящего трека
  static MixPlan manual(MixProfile out, MixProfile inn, TransitionPref pref, {MixPlan? auto}) {
    final tail = out.durationMs;
    final dj = pref.style == 'dj';
    final ob = out.bpm, ib = inn.bpm;
    final oh = out.tailBarMs ?? out.tailBeatMs, ih = inn.headBarMs ?? inn.headBeatMs;
    final grid = ob != null && ib != null && oh != null && ih != null && ob >= 60 && ob <= 200 && ib >= 60 && ib <= 200;

    // Ниже эти значения нужны, только когда сетка есть (useGrid); иначе в расчёт не попадают
    final bo = ob ?? 120.0, bi = ib ?? 120.0, ho = oh ?? 0, hi = ih ?? 0;
    // Темп: подгоняем, если просят и разница разумная (до 25 %)
    var rate = 1.0;
    if (dj && pref.sync && grid) {
      var best = double.infinity;
      for (final m in const [0.5, 1.0, 2.0]) {
        final r = bo * m / bi;
        if ((r - 1).abs() < (best - 1).abs()) best = r;
      }
      if ((best - 1).abs() <= 0.25) rate = best;
    }
    final useGrid = dj && grid;

    // Где начать в уходящем: заданное вручную, иначе автоматическое, иначе за длину до конца
    final lenMs = dj ? (grid ? (pref.bars * 4 * 60000 / bo).round() : pref.bars * 2000) : pref.seconds * 1000;
    var start = pref.outMs ?? auto?.start.inMilliseconds ?? math.max(0, out.endMs - lenMs);
    if (useGrid) start = snapToBeat(start, ho, bo, durationMs: tail);
    start = start.clamp(0, math.max(0, tail - 500)).toInt();
    final len = math.min(lenMs, math.max(500, tail - start));

    // С какого места начать следующий: заданное вручную, иначе после тишины в начале
    var enter = pref.inMs ?? math.min(inn.introMs, 8000);
    if (useGrid) enter = snapToBeat(enter, hi, bi, durationMs: inn.durationMs);
    enter = enter.clamp(0, math.max(0, inn.durationMs - 500)).toInt();

    final diff = (out.loudDb - inn.loudDb).clamp(-6.0, 6.0);
    final pre = Duration(milliseconds: useGrid ? math.min(700, (enter / rate).floor()) : 0);
    return MixPlan(
      Duration(milliseconds: start),
      Duration(milliseconds: len),
      Duration(milliseconds: enter),
      math.pow(10, diff / 20).toDouble(),
      dj: useGrid,
      rate: useGrid ? rate : 1.0,
      swapAt: useGrid && pref.bass && len >= 3000 ? Duration(milliseconds: (len / 2).round()) : null,
      grid: useGrid ? (ho.toDouble(), 60000 / bo, hi.toDouble(), 60000 / bi) : null,
      offsetMs: pref.offsetMs,
      preroll: pre,
    );
  }

  /// Диджейский переход; null — данных не хватает (нет темпа или сетки долей) или темпы слишком разные
  static MixPlan? _makeDj(MixProfile out, MixProfile inn, DjMix o) {
    final ob = out.bpm, ib = inn.bpm;
    // Если известна первая доля такта, привязываемся к тактам, иначе к долям
    final oh = out.tailBarMs ?? out.tailBeatMs, ih = inn.headBarMs ?? inn.headBeatMs;
    if (ob == null || ib == null || oh == null || ih == null) return null;
    if (ob < 60 || ob > 200 || ib < 60 || ib > 200) return null;
    // Темп следующего подгоняем под уходящий; двойной и половинный темп считаются совпадением
    var rate = double.infinity;
    for (final m in const [0.5, 1.0, 2.0]) {
      final r = ob * m / ib;
      if ((r - 1).abs() < (rate - 1).abs()) rate = r;
    }
    if ((rate - 1).abs() > o.range) return null;
    final tail = out.endMs;
    final beat = 60000 / ob;
    final bar = 4 * beat;
    var bars = o.bars.clamp(1, 64).toInt();
    // Тональности спорят: долгое наложение звучало бы разладом, поэтому переход короткий
    if (o.harmonic) {
      final ka = Camelot.parse(out.key), kb = Camelot.parse(inn.key);
      if (ka != null && kb != null && Camelot.compat(ka, kb) < 0.45) bars = math.min(bars, 2);
    }
    var len = bars * bar;
    // Переход не должен начинаться раньше, чем через 10 с после начала трека: если не помещается, укорачиваем вдвое
    while (bars > 1 && tail - len < out.introMs + 10000) {
      bars = (bars / 2).floor();
      len = bars * bar;
    }
    if (tail - len < out.introMs + 10000 - beat) return null;
    // Начало — на первой доле такта (или на доле) уходящего трека не позже, чем «конец минус длина»
    final unit = out.tailBarMs != null ? bar : beat;
    final k = ((tail - len - oh) / unit).floor();
    final start = (oh + k * unit).round();
    if (start < 0) return null;
    // Следующий входит на первой доле своего первого такта, после тишины в начале
    final ibeat = 60000 / ib;
    final iunit = inn.headBarMs != null ? 4 * ibeat : ibeat;
    final j = ((inn.introMs - ih) / iunit).ceil();
    final enter = (ih + j * iunit).round();
    if (enter < 0 || enter > 12000) return null;
    // Следующий трек запускаем чуть раньше (бесшумно), чтобы к началу перехода он уже играл ровно с нужной доли
    final pre = Duration(milliseconds: math.min(700, (enter / rate).floor()));
    final diff = (out.loudDb - inn.loudDb).clamp(-6.0, 6.0);
    final swap = o.bass && bars >= 2 ? Duration(milliseconds: (bars ~/ 2 * bar).round()) : null;
    return MixPlan(
      Duration(milliseconds: start),
      Duration(milliseconds: len.round()),
      Duration(milliseconds: enter),
      math.pow(10, diff / 20).toDouble(),
      dj: true,
      rate: rate,
      swapAt: swap,
      grid: (oh.toDouble(), beat, ih.toDouble(), ibeat),
      offsetMs: o.offsetMs,
      preroll: pre,
    );
  }
}

/// Считает профили треков в фоне и хранит их на диске
class MixAnalyzer {
  final Directory dir;
  final AudioCache cache;
  final Tools tools;
  MixAnalyzer(this.dir, this.cache, this.tools);

  /// Профиль трека посчитан (плеер по нему подстраивает громкость)
  void Function(String id)? onProfile;

  final Map<String, MixProfile> _mem = {};
  final Set<String> _queue = {};
  final Set<String> _tried = {}; // уже разбирали в этом запуске: упавший разбор не повторяем на каждом прослушивании
  bool _running = false;
  bool _noTool = false;

  /// Сколько треков ещё ждут разбора (для строки «Анализ: осталось N»)
  final ValueNotifier<int> pending = ValueNotifier(0);

  void _publish() => pending.value = _queue.length;

  File _file(String id) => File('${dir.path}${Platform.pathSeparator}mix_$id.json');

  /// Профиль, если уже посчитан
  MixProfile? profile(String id) {
    final m = _mem[id];
    if (m != null) return m;
    // Плеер спрашивает профиль на каждом отсчёте позиции: пока трек не разобран, не ходим каждый раз на диск.
    // Файл профиля появляется только из _analyze, а он сразу кладёт профиль в память
    if (_absent.contains(id)) return null;
    final f = _file(id);
    MixProfile? p;
    try {
      if (f.existsSync()) p = MixProfile.fromJson(jsonDecode(f.readAsStringSync()));
    } catch (_) {
      p = null;
    }
    if (p != null) {
      _mem[id] = p;
    } else {
      _absent.add(id);
    }
    return p;
  }

  /// Треки, у которых на диске нет читаемого профиля (чтобы не проверять это снова и снова)
  final Set<String> _absent = {};

  /// Профиль из памяти, без чтения диска: для проходов по всей библиотеке
  MixProfile? profileCached(String id) => _mem[id];

  /// Сколько профилей в памяти: по этому числу видно, что появились новые разборы
  int get profileCount => _mem.length;

  /// Читает сохранённые профили в память. Запускается в фоне при старте: потом по библиотеке можно ходить без диска
  Future<void> preload() async {
    try {
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!name.startsWith('mix_') || !name.endsWith('.json')) continue;
        final id = name.substring(4, name.length - 5);
        if (_mem.containsKey(id)) continue;
        try {
          final p = MixProfile.fromJson(jsonDecode(await e.readAsString()));
          if (p != null) _mem[id] = p;
        } catch (_) {
          // битый файл: профиль посчитается заново
        }
      }
    } catch (e) {
      AppLog.warn('АвтоDJ: не прочитались сохранённые профили', e);
    }
  }

  /// Посчитать профиль, когда звук трека будет в кэше
  void prepare(String id) {
    if (_noTool) return;
    final p = profile(id);
    // Старый профиль без темпа и тональности досчитываем, только если звук уже в кэше: ради этого трек не качаем
    if (p != null && (p.v >= MixProfile.version || _tried.contains(id) || !cache.has(id))) return;
    _queue.add(id);
    _publish();
    unawaited(_pump());
  }

  /// Пакетный разбор, например плейлиста для АвтоDJ: недостающие треки докачиваются в кэш и разбираются по очереди.
  /// Возвращает, сколько треков поставлено в очередь
  int prepareMany(Iterable<String> ids) {
    if (_noTool) return 0;
    var n = 0;
    for (final id in ids) {
      final p = profile(id);
      if (p != null && p.v >= MixProfile.version) continue;
      if (!cache.has(id)) cache.enqueue(id);
      _tried.remove(id);
      if (_queue.add(id)) n++;
    }
    _publish();
    unawaited(_pump());
    return n;
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final id = _queue.first;
        final src = cache.fileFor(id);
        // Звука ещё нет — ждём, пока кэш его докачает (плеер качает следующий трек заранее)
        var waited = 0;
        while (!(cache.has(id) && src.existsSync()) && waited < 120) {
          await Future<void>.delayed(const Duration(seconds: 2));
          waited += 2;
        }
        _queue.remove(id);
        _publish();
        if (!(cache.has(id) && src.existsSync())) continue;
        await _analyze(id, src);
      }
    } finally {
      _running = false;
      _publish();
    }
  }

  Future<void> _analyze(String id, File src) async {
    _tried.add(id);
    try {
      if (!tools.ffmpeg.existsSync()) {
        await tools.ensure((_) {});
        if (!tools.ffmpeg.existsSync()) {
          _noTool = true;
          return;
        }
      }
      await dir.create(recursive: true);
      final raw = File('${dir.path}${Platform.pathSeparator}mix_work.raw');
      // Моно, 4 кГц, 16 бит — для огибающей громкости этого хватает с запасом
      await Tools.run(tools.ffmpeg.path, ['-y', '-v', 'error', '-i', src.path, '-ac', '1', '-ar', '4000', '-f', 's16le', raw.path]);
      if (!raw.existsSync()) return;
      final bytes = await raw.readAsBytes();
      await raw.delete();
      final base = MixProfile.fromEnvelope(envelope(bytes));
      if (base == null) return;
      // Темп, доли и тональность — в отдельном изоляте: на длинном треке это секунды работы
      AudioAnalysis? a;
      var failed = false;
      try {
        a = await analyzeInIsolate(bytes, introMs: base.introMs, endMs: base.endMs);
      } catch (e) {
        failed = true;
        AppLog.warn('АвтоDJ: не посчитались темп и тональность', e);
      }
      final tags = await _readTags(src);
      // Если разбор упал, сохраняем прежний профиль без отметки о новой версии: попробуем в следующий раз
      final p = failed ? base : base.withAnalysis(a, tagBpm: tags.$1, tagKey: tags.$2, genre: tags.$3);
      _mem[id] = p;
      _absent.remove(id);
      await _file(id).writeAsString(jsonEncode(p.toJson()));
      onProfile?.call(id);
    } catch (e) {
      AppLog.warn('Умный переход: не посчитался звук', e);
    }
  }

  /// Теги из самого файла: темп, тональность и жанр (их вписывают Mixxx, Traktor, Beatport и другие)
  Future<(double?, String?, String)> _readTags(File src) async {
    try {
      final out = File('${dir.path}${Platform.pathSeparator}mix_tags.txt');
      if (out.existsSync()) await out.delete();
      await Tools.run(tools.ffmpeg.path, ['-y', '-v', 'error', '-i', src.path, '-f', 'ffmetadata', out.path]);
      if (!out.existsSync()) return (null, null, '');
      final text = utf8.decode(await out.readAsBytes(), allowMalformed: true);
      await out.delete();
      return parseTagText(text);
    } catch (_) {
      return (null, null, '');
    }
  }

  /// Темп, тональность и жанр из текста, который отдаёт ffmpeg (`ключ=значение` построчно)
  static (double?, String?, String) parseTagText(String text) {
    double? bpm;
    String? key;
    var genre = '';
    for (final line in text.split('\n')) {
      final i = line.indexOf('=');
      if (i <= 0 || line.startsWith(';')) continue;
      final k = line.substring(0, i).trim().toLowerCase();
      final v = line.substring(i + 1).trim();
      if (v.isEmpty) continue;
      switch (k) {
        case 'bpm':
        case 'tbpm':
        case 'tempo':
        case 'tmpo':
          bpm ??= double.tryParse(v.replaceAll(',', '.'));
        case 'initialkey':
        case 'initial_key':
        case 'tkey':
        case 'key':
          key ??= v;
        case 'genre':
        case 'tcon':
          if (genre.isEmpty) genre = v.toLowerCase();
      }
    }
    return (bpm, key, genre);
  }

  /// PCM 16 бит моно 4 кГц → громкость в дБ на каждые 50 мс
  static List<double> envelope(Uint8List pcm, {int rate = 4000, int frameMs = 50}) {
    final data = ByteData.sublistView(pcm);
    final n = pcm.length ~/ 2;
    final frame = rate * frameMs ~/ 1000;
    final out = <double>[];
    for (var i = 0; i + frame <= n; i += frame) {
      var s = 0.0;
      for (var k = i; k < i + frame; k++) {
        final v = data.getInt16(k * 2, Endian.little) / 32768.0;
        s += v * v;
      }
      final rms = math.sqrt(s / frame);
      out.add(rms <= 1e-6 ? -120 : 20 * math.log(rms) / math.ln10);
    }
    return out;
  }
}
