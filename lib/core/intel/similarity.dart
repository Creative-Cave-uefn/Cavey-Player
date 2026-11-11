import 'dart:math' as math;
import 'dart:typed_data';

import '../beats.dart' show tonicOf;
import '../dj.dart' show Camelot, bpmStretch;
import 'record.dart';

// Похожесть треков по звуку: сравнение уже посчитанных признаков, без звука, GPU и нейросетей.
//
// Признаки собраны в четыре группы: тембр, гармония, ритм, динамика. Каждая группа нормализуется по статистике
// СВОЕЙ библиотеки (по каждому признаку отдельно), расстояние внутри группы переводится в похожесть 0…1.
// Группы складываются с весами режима («похожее звучание», «похожая энергия», «DJ-совместимость»), а вес группы
// умножается на уверенность в ней у обеих записей: если у трека нет надёжного темпа или тональности,
// соответствующая группа почти не влияет на результат. Случайности нет: одинаковые входные данные дают одинаковый порядок.
//
// Уточнения:
// • Нормализация признаков — по медиане и MAD (устойчива к редким резким трекам в библиотеке), не по среднему и σ.
// • В режимах «звук» и «энергия» гармония сравнивается хромой, повёрнутой к тонике (если тональность надёжна):
//   так совпадают песни с похожим складом аккордов независимо от конкретной тональности. В режиме «DJ» используется
//   исходная (не повёрнутая) хрома плюс совместимость по кругу Camelot — там важна именно тональность, не узор.
// • Де-хабинг: у каждого трека посчитана «типичная похожесть на случайную выборку библиотеки» (центральность).
//   Она вычитается из итоговой оценки, чтобы «усреднённые» треки не лезли в соседи всем подряд (проблема хабов,
//   как в Musly — там это Mutual Proximity; здесь упрощённый вариант, без полной матрицы расстояний).
//   Считается только пока в библиотеке не больше centralityCap записей — иначе слишком дорого, и поправка не применяется.
// • В режиме «DJ» дополнительно жёсткий отсев: темп, который не свести подгонкой даже с учётом удвоения/половины,
//   и тональности, которые совсем не сочетаются по Camelot, не предлагаются вовсе (не просто меньше весят).

/// Для чего подбираем похожие
enum SimilarityMode {
  /// Похожее звучание: тембр важнее всего
  sound,

  /// Похожая энергия: громкость, динамика, ритмическая плотность
  energy,

  /// Совместимость для сведения: темп и тональность важнее тембра
  dj,
}

/// Названия групп признаков в [SimilarityHit.groups]
const String groupTimbre = 'timbre';
const String groupHarmony = 'harmony';
const String groupRhythm = 'rhythm';
const String groupDynamics = 'dynamics';

/// Один найденный трек
class SimilarityHit {
  final String id;

  /// Похожесть, около 0…1 (с отрицательными примерами может уйти ниже нуля)
  final double score;

  /// Насколько результату можно верить: 1 — все группы признаков надёжны у обоих треков, 0 — сравнивать почти нечем
  final double confidence;

  /// Похожесть по каждой группе (timbre, harmony, rhythm, dynamics), 0…1 — чтобы объяснить, почему трек подошёл
  final Map<String, double> groups;

  /// Какой из исходных треков оказался ближе всего
  final String? nearestSeed;

  const SimilarityHit(this.id, this.score, this.confidence, this.groups, {this.nearestSeed});

  @override
  String toString() => 'SimilarityHit($id, ${score.toStringAsFixed(3)}, conf ${confidence.toStringAsFixed(2)})';
}

/// Насколько один трек подходит для сведения после другого
class TransitionFit {
  final double score;
  final double confidence;
  final Map<String, double> parts;
  const TransitionFit(this.score, this.confidence, this.parts);
}

const int _timbreDims = 34;
const int _harmonyDims = 12;
const int _dynDims = 6;

const Map<SimilarityMode, List<double>> _weights = {
  // timbre, harmony, rhythm, dynamics
  SimilarityMode.sound: [0.50, 0.20, 0.15, 0.15],
  SimilarityMode.energy: [0.15, 0.00, 0.30, 0.55],
  SimilarityMode.dj: [0.10, 0.30, 0.40, 0.20],
};

List<double> _timbreOf(TrackFeatures f) => [
      ...f.mfccMean,
      ...f.mfccStd,
      f.centroidMean,
      f.centroidStd,
      f.rolloffMean,
      f.flatnessMean,
      ...f.contrast,
    ];

List<double> _dynOf(TrackFeatures f) => [f.rmsDb, f.dynamicRangeDb, f.bassRatio, f.midRatio, f.energyStdDb, f.lufs ?? f.rmsDb];

double _clamp01(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

/// Индекс признаков библиотеки: хранит записи и готовые нормализованные векторы для быстрого сравнения
class IntelIndex {
  final Map<String, int> _pos = {};
  List<TrackFeatures> _rec = const [];

  Float32List _timbre = Float32List(0);
  Float32List _harmony = Float32List(0);

  /// Хрома, повёрнутая так, чтобы тоника трека оказалась в одном и том же месте (для режимов «звук» и «энергия»):
  /// совпадает узор аккордов, а не конкретная высота. Без надёжной тональности — не повёрнута (как [_harmony])
  Float32List _harmonyRel = Float32List(0);
  Float32List _dyn = Float32List(0);
  Float64List _onset = Float64List(0); // нормализованная ритмическая плотность
  Float64List _bpm = Float64List(0); // 0 — темп ненадёжен
  Float64List _cBase = Float64List(0);
  Float64List _cRhythm = Float64List(0);
  Float64List _cKey = Float64List(0);
  List<Camelot?> _keys = const [];

  /// «Типичная похожесть на случайную выборку библиотеки» — вычитается из оценки, чтобы «усреднённые»
  /// треки не оказывались в соседях у всех подряд (де-хабинг). Нули — библиотека больше [_centralityCap] или записей мало
  Float64List _centrality = Float64List(0);
  static const int _centralityCap = 4000;
  static const int _centralitySample = 48;
  static const double _centralityGamma = 0.12;

  int get count => _rec.length;
  bool has(String id) => _pos.containsKey(id);
  TrackFeatures? of(String id) {
    final i = _pos[id];
    return i == null ? null : _rec[i];
  }

  Iterable<TrackFeatures> get all => _rec;

  /// Запись по порядковому номеру (для карты)
  TrackFeatures recordAt(int i) => _rec[i];

  /// Центральность записи (0 — не хаб, выше — чаще оказывается «похожей на всё»). 0, если не считалась (см. [_centralityCap])
  double centralityAt(int i) => i >= 0 && i < _centrality.length ? _centrality[i] : 0.0;

  /// Длина вектора [embeddingInto]: тембр, гармония, динамика и ритмическая плотность
  static const int embeddingDims = _timbreDims + _harmonyDims + _dynDims + 1;

  /// Нормализованный по библиотеке вектор признаков записи [i]; по нему строится карта схожести
  void embeddingInto(int i, Float64List out) {
    var k = 0;
    for (var d = 0; d < _timbreDims; d++) {
      out[k++] = _timbre[i * _timbreDims + d];
    }
    for (var d = 0; d < _harmonyDims; d++) {
      out[k++] = _harmony[i * _harmonyDims + d];
    }
    for (var d = 0; d < _dynDims; d++) {
      out[k++] = _dyn[i * _dynDims + d];
    }
    out[k] = _onset[i];
  }

  /// Пересобирает индекс из записей (по одной на трек). Нормализация считается по этим записям
  void rebuild(Iterable<TrackFeatures> records) {
    _rec = List<TrackFeatures>.of(records);
    final n = _rec.length;
    _pos
      ..clear()
      ..addEntries([for (var i = 0; i < n; i++) MapEntry(_rec[i].trackId, i)]);

    // Тональности нужны заранее: по ним поворачивается хрома для _harmonyRel
    _keys = List<Camelot?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      _keys[i] = Camelot.parse(_rec[i].key);
    }

    final rawT = List<List<double>>.generate(n, (i) => _timbreOf(_rec[i]));
    final rawH = List<List<double>>.generate(n, (i) => _rec[i].chroma);
    final rawHRel = List<List<double>>.generate(n, (i) => _rotateChroma(_rec[i]));
    final rawD = List<List<double>>.generate(n, (i) => _dynOf(_rec[i]));
    final rawO = [for (final r in _rec) r.onsetDensity];

    _timbre = _normalize(rawT, _timbreDims);
    _harmony = _normalize(rawH, _harmonyDims);
    _harmonyRel = _normalize(rawHRel, _harmonyDims);
    _dyn = _normalize(rawD, _dynDims);
    _onset = Float64List.fromList(_normalizeScalar(rawO));
    _bpm = Float64List(n);
    _cBase = Float64List(n);
    _cRhythm = Float64List(n);
    _cKey = Float64List(n);
    for (var i = 0; i < n; i++) {
      final r = _rec[i];
      var base = _clamp01(r.coverageSec / 60.0);
      if (r.coverageSec > 0 && base < 0.25) base = 0.25;
      if (r.hasFlag(TrackFeatures.flagShort)) base *= 0.5;
      _cBase[i] = base;
      if (r.tempoReliable) {
        _bpm[i] = r.bpm!;
        _cRhythm[i] = _clamp01((r.bpmConf - 0.05) / 0.25) * (0.5 + 0.5 * _clamp01(r.tempoStability));
      }
      _cKey[i] = _keys[i] == null ? 0.0 : _clamp01((r.keyConf - 0.2) / 0.4);
    }
    _computeCentrality();
  }

  /// Хрома, повёрнутая так, чтобы тоника записи оказалась в позиции 0 (узор аккордов без привязки к высоте).
  /// Тональность ненадёжна или не распознана — хрома возвращается как есть (нейтральный, но заведомо не ложный вариант)
  List<double> _rotateChroma(TrackFeatures r) {
    final chroma = r.chroma;
    if (!r.keyReliable) return chroma;
    final k = Camelot.parse(r.key);
    if (k == null) return chroma;
    final t = tonicOf(k.n, k.minor);
    if (t == null || t == 0) return chroma;
    return [for (var i = 0; i < 12; i++) chroma[(t + i) % 12]];
  }

  /// Насколько сильно считать гармонию по-тонически (режимы «звук»/«энергия»): меньше при ненадёжной тональности,
  /// чтобы «неизвестная тоника» не выглядела как заведомое совпадение с «тоникой C»
  double _keyBoost(int i) => 0.55 + 0.45 * _cKey[i];

  /// Типичная похожесть записи [i] на случайную выборку библиотеки: тембр, повёрнутая гармония и динамика
  /// в равных долях, без учёта ритма и ключевой совместимости (та часть, что не зависит от режима).
  /// Считается только пока записей не больше [_centralityCap]: иначе O(n·sample) становится заметным на главном потоке
  void _computeCentrality() {
    final n = _rec.length;
    _centrality = Float64List(n);
    if (n < 8 || n > _centralityCap) return;
    final m = math.min(n, _centralitySample);
    // Равномерная выборка по индексам — детерминированно и не зависит от порядка записей
    final sampleIdx = List<int>.generate(m, (k) => (k * n / m).floor());
    for (var i = 0; i < n; i++) {
      var sum = 0.0;
      var cnt = 0;
      for (final j in sampleIdx) {
        if (j == i) continue;
        final t = _vecSim(_timbre, _timbre, _timbreDims, i, j);
        final h = _vecSim(_harmonyRel, _harmonyRel, _harmonyDims, i, j);
        final d = _vecSim(_dyn, _dyn, _dynDims, i, j);
        sum += (t + h + d) / 3;
        cnt++;
      }
      _centrality[i] = cnt == 0 ? 0.0 : sum / cnt;
    }
  }

  /// Каждый признак: (x − медиана) / (1,4826 × MAD) по библиотеке, значения ограничены ±4.
  /// Медиана и MAD устойчивее среднего и σ: один резкий трек (например, очень громкий или очень быстрый)
  /// не сдвигает нормализацию для всех остальных так, как это сделало бы среднее
  static Float32List _normalize(List<List<double>> rows, int dims) {
    final n = rows.length;
    final out = Float32List(n * dims);
    if (n == 0) return out;
    final col = List<double>.filled(n, 0);
    for (var d = 0; d < dims; d++) {
      for (var i = 0; i < n; i++) {
        col[i] = rows[i][d];
      }
      final (m, mad) = _medianMad(col);
      var sd = mad * 1.4826;
      if (sd < 1e-9) sd = 1.0;
      for (var i = 0; i < n; i++) {
        out[i * dims + d] = ((rows[i][d] - m) / sd).clamp(-4.0, 4.0).toDouble();
      }
    }
    return out;
  }

  static List<double> _normalizeScalar(List<double> v) {
    final n = v.length;
    if (n == 0) return const [];
    final (m, mad) = _medianMad(v);
    var sd = mad * 1.4826;
    if (sd < 1e-9) sd = 1.0;
    return [for (final x in v) ((x - m) / sd).clamp(-4.0, 4.0).toDouble()];
  }

  static double mean(List<double> v) {
    var s = 0.0;
    for (final x in v) {
      s += x;
    }
    return v.isEmpty ? 0.0 : s / v.length;
  }

  static double _median(List<double> sorted) {
    final n = sorted.length;
    if (n == 0) return 0.0;
    return n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
  }

  /// Медиана и медиана абсолютных отклонений от неё (MAD), не меняет [v]
  static (double, double) _medianMad(List<double> v) {
    if (v.isEmpty) return (0.0, 0.0);
    final s = List<double>.of(v)..sort();
    final m = _median(s);
    final dev = [for (final x in v) (x - m).abs()]..sort();
    return (m, _median(dev));
  }

  double _vecSim(Float32List a, Float32List b, int dims, int i, int j) {
    var s = 0.0;
    final ai = i * dims, bj = j * dims;
    for (var d = 0; d < dims; d++) {
      final x = a[ai + d] - b[bj + d];
      s += x * x;
    }
    return math.exp(-0.5 * s / dims);
  }

  /// Похожесть по четырём группам и уверенность в каждой. Результат — в [sims] и [confs] (длина 4).
  /// [mode] выбирает, как сравнивается гармония: в «DJ» — исходная хрома плюс совместимость по Camelot (важна
  /// именно тональность), в остальных режимах — хрома, повёрнутая к тонике (важен узор аккордов, а не высота)
  void _groups(int i, int j, Float64List sims, Float64List confs, SimilarityMode mode) {
    final base = math.sqrt(_cBase[i] * _cBase[j]);
    sims[0] = _vecSim(_timbre, _timbre, _timbreDims, i, j);
    confs[0] = base;

    if (mode == SimilarityMode.dj) {
      var h = _vecSim(_harmony, _harmony, _harmonyDims, i, j);
      final ki = _keys[i], kj = _keys[j];
      if (ki != null && kj != null) {
        final kw = 0.35 * math.sqrt(_cKey[i] * _cKey[j]);
        h = h * (1 - kw) + Camelot.compat(ki, kj) * kw;
      }
      sims[1] = h;
      confs[1] = base;
    } else {
      sims[1] = _vecSim(_harmonyRel, _harmonyRel, _harmonyDims, i, j);
      confs[1] = base * _keyBoost(i) * _keyBoost(j);
    }

    final od = _onset[i] - _onset[j];
    final onsetSim = math.exp(-0.5 * od * od);
    if (_bpm[i] > 0 && _bpm[j] > 0) {
      // 5 % разницы в темпе — ещё близко, 10 % — уже заметно, 20 % — разные песни
      final d = bpmStretch(_bpm[i], _bpm[j]);
      final bpmSim = math.exp(-0.5 * (d / 0.08) * (d / 0.08));
      sims[2] = 0.75 * bpmSim + 0.25 * onsetSim;
      confs[2] = math.sqrt(_cRhythm[i] * _cRhythm[j]);
    } else {
      // Темпа нет хотя бы у одного трека: остаётся только плотность атак, и верим ей слабо
      sims[2] = onsetSim;
      confs[2] = 0.25 * base;
    }

    sims[3] = _vecSim(_dyn, _dyn, _dynDims, i, j);
    confs[3] = base;
  }

  (double, double) _combine(Float64List sims, Float64List confs, List<double> w) {
    var num = 0.0, den = 0.0, wTotal = 0.0;
    for (var g = 0; g < 4; g++) {
      final eff = w[g] * confs[g];
      num += eff * sims[g];
      den += eff;
      wTotal += w[g];
    }
    if (den <= 1e-9 || wTotal <= 0) return (0.0, 0.0);
    return (num / den, den / wTotal);
  }

  /// Оценка после вычитания де-хабинга (центральность — см. [_computeCentrality]); уверенность не меняется
  double _deHub(double score, int i, int j) => score - _centralityGamma * (_centrality[i] + _centrality[j]) / 2;

  static Map<String, double> _named(Float64List sims) => {
        groupTimbre: sims[0],
        groupHarmony: sims[1],
        groupRhythm: sims[2],
        groupDynamics: sims[3],
      };

  /// Сравнение двух треков. null — одного из них нет в индексе
  SimilarityHit? compare(String a, String b, {SimilarityMode mode = SimilarityMode.sound}) {
    final i = _pos[a], j = _pos[b];
    if (i == null || j == null) return null;
    final sims = Float64List(4), confs = Float64List(4);
    _groups(i, j, sims, confs, mode);
    final r = _combine(sims, confs, _weights[mode]!);
    return SimilarityHit(b, _deHub(r.$1, i, j), r.$2, _named(sims), nearestSeed: a);
  }

  /// Подбор похожих.
  ///
  /// [seeds] — исходные треки (вес 1). [taste] — вес на трек: положительные притягивают, отрицательные (например,
  /// недавно пропущенные) отталкивают: из итога вычитается половина наибольшей похожести на «отталкивающие».
  /// Своих исходников, треков из [exclude] и явных повторов одной записи в выдаче нет. [allow] отсекает недоступные.
  /// Порядок воспроизводим: сначала выше оценка, при равенстве — по id.
  List<SimilarityHit> similar({
    Iterable<String> seeds = const [],
    Map<String, double> taste = const {},
    SimilarityMode mode = SimilarityMode.sound,
    int limit = 20,
    Set<String> exclude = const {},
    bool Function(String id)? allow,
    double minScore = 0.0,
    double minConfidence = 0.0,
    bool dropDuplicates = true,
  }) {
    final pos = <(int, double)>[];
    final neg = <(int, double)>[];
    final seedSet = <String>{};
    for (final id in seeds) {
      final i = _pos[id];
      if (i != null && seedSet.add(id)) pos.add((i, 1.0));
    }
    taste.forEach((id, w) {
      final i = _pos[id];
      if (i == null || w == 0) return;
      if (w > 0) {
        if (seedSet.add(id)) pos.add((i, w));
      } else {
        neg.add((i, -w));
        seedSet.add(id);
      }
    });
    if (pos.isEmpty || limit <= 0) return const [];

    final w = _weights[mode]!;
    final sims = Float64List(4), confs = Float64List(4);
    // Режим DJ: темп, который не свести подгонкой даже с удвоением/половиной, и тональности, которые совсем
    // не сочетаются по Camelot, вообще не предлагаются — это жёсткий отсев, а не просто меньший вес
    final djHard = mode == SimilarityMode.dj;
    final cand = <(int, double, double, int)>[]; // индекс, оценка, уверенность, номер ближайшего исходника
    for (var j = 0; j < _rec.length; j++) {
      final id = _rec[j].trackId;
      if (seedSet.contains(id) || exclude.contains(id)) continue;
      if (allow != null && !allow(id)) continue;
      var best = double.negativeInfinity, bestConf = 0.0;
      var bestSeed = -1;
      var duplicate = false;
      for (var s = 0; s < pos.length; s++) {
        final i = pos[s].$1;
        if (djHard && !_djAllowed(i, j)) continue;
        _groups(i, j, sims, confs, mode);
        final r = _combine(sims, confs, w);
        if (dropDuplicates && _sameRecording(i, j, sims)) {
          duplicate = true;
          break;
        }
        final v = _deHub(r.$1, i, j) * pos[s].$2;
        if (v > best) {
          best = v;
          bestConf = r.$2;
          bestSeed = s;
        }
      }
      if (duplicate || bestSeed < 0) continue;
      var negMax = 0.0;
      for (final (i, nw) in neg) {
        _groups(i, j, sims, confs, mode);
        final v = _deHub(_combine(sims, confs, w).$1, i, j) * nw;
        if (v > negMax) negMax = v;
      }
      final score = best - 0.5 * negMax;
      if (score < minScore || bestConf < minConfidence) continue;
      cand.add((j, score, bestConf, bestSeed));
    }
    cand.sort((a, b) {
      final c = b.$2.compareTo(a.$2);
      return c != 0 ? c : _rec[a.$1].trackId.compareTo(_rec[b.$1].trackId);
    });
    final out = <SimilarityHit>[];
    for (final c in cand.take(limit)) {
      final seed = pos[c.$4].$1;
      _groups(seed, c.$1, sims, confs, mode);
      out.add(SimilarityHit(_rec[c.$1].trackId, c.$2, c.$3, _named(sims), nearestSeed: _rec[seed].trackId));
    }
    return out;
  }

  /// DJ-режим: можно ли вообще предлагать [j] на замену/после [i]. Не фильтр похожести — просто то, что
  /// физически не сведёшь (темп даже с удвоением/половиной не подогнать) или что будет откровенно спорить
  /// по тональности (Camelot.compat == 0). Данных нет хотя бы по одной стороне — не отсеиваем, решать нечем
  bool _djAllowed(int i, int j) {
    if (_bpm[i] > 0 && _bpm[j] > 0 && bpmStretch(_bpm[i], _bpm[j]) > 0.2) return false;
    final ki = _keys[i], kj = _keys[j];
    if (ki != null && kj != null && Camelot.compat(ki, kj) < 0.1) return false;
    return true;
  }

  /// Это, скорее всего, та же запись: звук совпадает почти полностью и длительность одинаковая
  bool _sameRecording(int i, int j, Float64List sims) {
    if (sims[0] < 0.985 || sims[1] < 0.985 || sims[3] < 0.985) return false;
    return (_rec[i].durationSec - _rec[j].durationSec).abs() < 2.5;
  }

  /// Ограничивает число треков одного исполнителя в выдаче, сохраняя порядок. [artistOf] — ключ исполнителя по id
  static List<SimilarityHit> diversify(List<SimilarityHit> hits, String Function(String id) artistOf, {int maxPerArtist = 2, int? limit}) {
    final per = <String, int>{};
    final out = <SimilarityHit>[];
    for (final h in hits) {
      final a = artistOf(h.id);
      final n = per[a] ?? 0;
      if (n >= maxPerArtist) continue;
      per[a] = n + 1;
      out.add(h);
      if (limit != null && out.length >= limit) break;
    }
    return out;
  }

  /// Насколько трек [b] подходит для сведения после [a]: темп (с учётом двойного и половинного), тональность,
  /// плавность по энергии (концовка A → вступление B), громкость и наличие бита на стыке.
  /// Сходство тембра сюда не входит намеренно: похожий тембр не делает стык бесшовным.
  TransitionFit? transition(String a, String b) {
    final fa = of(a), fb = of(b);
    if (fa == null || fb == null) return null;
    final parts = <String, double>{};
    var num = 0.0, den = 0.0, wTotal = 0.0;
    void add(String name, double w, double? v, double conf) {
      wTotal += w;
      if (v == null || conf <= 0) return;
      parts[name] = v;
      num += w * conf * v;
      den += w * conf;
    }

    if (fa.tempoReliable && fb.tempoReliable) {
      final d = bpmStretch(fa.bpm!, fb.bpm!);
      final c = math.sqrt(_clamp01((fa.bpmConf - 0.05) / 0.25) * _clamp01((fb.bpmConf - 0.05) / 0.25));
      add('tempo', 0.35, math.exp(-(d / 0.06) * (d / 0.06)), math.max(0.2, c));
    } else {
      add('tempo', 0.35, null, 0);
    }
    final ka = Camelot.parse(fa.key), kb = Camelot.parse(fb.key);
    if (ka != null && kb != null) {
      final c = math.sqrt(_clamp01((fa.keyConf - 0.2) / 0.4) * _clamp01((fb.keyConf - 0.2) / 0.4));
      add('key', 0.25, Camelot.compat(ka, kb), c);
    } else {
      add('key', 0.25, null, 0);
    }
    final oa = fa.outro, ib = fb.intro;
    if (oa != null && ib != null) {
      final step = (oa.energyDb - ib.energyDb).abs();
      add('energy', 0.15, math.exp(-(step / 6.0) * (step / 6.0)), 1.0);
      add('beat', 0.15, (oa.hasBeat ? 0.5 : 0.0) + (ib.hasBeat ? 0.5 : 0.0), 1.0);
    } else {
      add('energy', 0.15, null, 0);
      add('beat', 0.15, null, 0);
    }
    if (fa.lufs != null && fb.lufs != null) {
      final d = (fa.lufs! - fb.lufs!).abs();
      add('loudness', 0.10, math.exp(-(d / 5.0) * (d / 5.0)), 1.0);
    } else {
      add('loudness', 0.10, null, 0);
    }
    if (den <= 1e-9) return TransitionFit(0, 0, parts);
    return TransitionFit(num / den, den / wTotal, parts);
  }
}
