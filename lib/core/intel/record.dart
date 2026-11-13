import 'dart:convert';
import 'dart:typed_data';
import 'sections.dart';

// Запись признаков одного трека — то, что хранится в локальном индексе и общих файлах на Диске.
// Общая часть компактна; необязательные локальные окна v2 увеличивают размер с длительностью трека. Спектрограммы не хранятся.
// У каждой записи есть стабильный id трека, версия содержимого файла, версии схемы и анализатора,
// сколько звука разобрано и признаки уверенности.

const List<double> _scales = [1.0, 10.0, 100.0, 1000.0, 10000.0];

/// Округление до [digits] знаков после запятой (0…4): так запись остаётся компактной
double _r(double v, [int digits = 3]) {
  if (v.isNaN || v.isInfinite) return 0.0;
  final k = _scales[digits.clamp(0, 4).toInt()];
  return (v * k).round() / k;
}

List<double> _rl(List<double> v, [int digits = 3]) => [for (final x in v) _r(x, digits)];

List<double> _dl(Object? raw, int n) {
  if (raw is List && raw.length == n) {
    return [for (final x in raw) (x as num).toDouble()];
  }
  return List<double>.filled(n, 0.0);
}

double _d(Object? v, [double def = 0.0]) => v is num ? v.toDouble() : def;
double? _dn(Object? v) => v is num ? v.toDouble() : null;
int? _in(Object? v) => v is num ? v.toInt() : null;

/// Признаки вступления или концовки трека (отдельно от трека в целом: нужны для сведения)
class SegmentStats {
  /// Средняя громкость, дБ
  final double energyDb;
  final double centroidHz;
  final double bassRatio;

  /// Атак в секунду: ≈0 — ритма нет (эмбиент, пауза), больше 1,5 — бит идёт
  final double onsetDensity;
  final List<double> mfcc;

  /// Тишина в начале (для вступления) или в конце (для концовки), мс
  final int silenceMs;

  const SegmentStats({
    required this.energyDb,
    required this.centroidHz,
    required this.bassRatio,
    required this.onsetDensity,
    required this.mfcc,
    required this.silenceMs,
  });

  bool get hasBeat => onsetDensity >= 1.2;

  Map<String, dynamic> toJson() => {
        'e': _r(energyDb, 1),
        'c': _r(centroidHz, 0),
        'b': _r(bassRatio),
        'o': _r(onsetDensity, 2),
        'm': _rl(mfcc, 2),
        's': silenceMs,
      };

  static SegmentStats? fromJson(Object? j) {
    if (j is! Map) return null;
    return SegmentStats(
      energyDb: _d(j['e'], -60),
      centroidHz: _d(j['c']),
      bassRatio: _d(j['b']),
      onsetDensity: _d(j['o']),
      mfcc: _dl(j['m'], 12),
      silenceMs: _in(j['s']) ?? 0,
    );
  }
}

/// Данные для будущего DJ-сведения (считаются по полному треку)
class DjData {
  /// Темп сетки долей и положение первой доли, мс; null — сетку построить не удалось
  final double? gridBpm;
  final int? firstBeatMs;

  /// Где в начале трека начинается такт (первая доля), мс; null — какая из долей первая, не определено
  final int? barAnchorMs;

  /// Сильная доля в начале и ближе к концу трека, мс, и начало такта там же
  final int? headBeatMs;
  final int? tailBeatMs;
  final int? headBarMs;
  final int? tailBarMs;

  /// Наибольшее расхождение сетки с реальными атаками по ходу трека, мс; сетка стабильна, если оно небольшое
  final double? driftMs;
  final bool gridStable;

  /// Границы музыкальных фраз, мс (кратны тактам от [barAnchorMs] или [firstBeatMs]); [phraseBars] — длина фразы в тактах
  final List<int> phrasesMs;
  final int phraseBars;

  /// Уверенность в выборе длины фразы, 0…1 (0 — границы просто предположены по восемь тактов)
  final double phraseConf;

  /// Кривые по секундам, 1 байт на секунду: громкость (значение − 100 = дБ) и «присутствие вокала» (0…100, эвристика)
  final Uint8List energyCurve;
  final Uint8List vocalCurve;

  const DjData({
    this.gridBpm,
    this.firstBeatMs,
    this.barAnchorMs,
    this.headBeatMs,
    this.tailBeatMs,
    this.headBarMs,
    this.tailBarMs,
    this.driftMs,
    this.gridStable = false,
    this.phrasesMs = const [],
    this.phraseBars = 8,
    this.phraseConf = 0,
    required this.energyCurve,
    required this.vocalCurve,
  });

  /// Громкость в секунду [s], дБ; null — вне трека
  double? energyAt(int s) => s >= 0 && s < energyCurve.length ? energyCurve[s] - 100.0 : null;

  /// Присутствие вокала в секунду [s], 0…1 (эвристика по средним частотам; не заменяет разделение голоса)
  double? vocalAt(int s) => s >= 0 && s < vocalCurve.length ? vocalCurve[s] / 100.0 : null;

  Map<String, dynamic> toJson() => {
        if (gridBpm != null) 'gb': _r(gridBpm!, 2),
        if (firstBeatMs != null) 'fb': firstBeatMs,
        if (barAnchorMs != null) 'bar': barAnchorMs,
        if (headBeatMs != null) 'hb': headBeatMs,
        if (tailBeatMs != null) 'tb': tailBeatMs,
        if (headBarMs != null) 'hbar': headBarMs,
        if (tailBarMs != null) 'tbar': tailBarMs,
        if (driftMs != null) 'dr': _r(driftMs!, 1),
        'gs': gridStable ? 1 : 0,
        'ph': phrasesMs,
        'pb': phraseBars,
        'pc': _r(phraseConf, 2),
        'ec': base64Encode(energyCurve),
        'vc': base64Encode(vocalCurve),
      };

  static DjData? fromJson(Object? j) {
    if (j is! Map) return null;
    Uint8List bytes(Object? s) {
      if (s is! String || s.isEmpty) return Uint8List(0);
      try {
        return base64Decode(s);
      } catch (_) {
        return Uint8List(0);
      }
    }

    final ph = j['ph'];
    return DjData(
      gridBpm: _dn(j['gb']),
      firstBeatMs: _in(j['fb']),
      barAnchorMs: _in(j['bar']),
      headBeatMs: _in(j['hb']),
      tailBeatMs: _in(j['tb']),
      headBarMs: _in(j['hbar']),
      tailBarMs: _in(j['tbar']),
      driftMs: _dn(j['dr']),
      gridStable: j['gs'] == 1,
      phrasesMs: ph is List ? [for (final x in ph) (x as num).toInt()] : const [],
      phraseBars: _in(j['pb']) ?? 8,
      phraseConf: _d(j['pc']),
      energyCurve: bytes(j['ec']),
      vocalCurve: bytes(j['vc']),
    );
  }
}

/// Результат разбора звука одного трека
class TrackFeatures {
  /// Версия схемы записи: меняется, когда меняется состав полей
  static const int schemaVersion = 1;

  /// Версия анализатора: растёт, когда меняются алгоритмы. Записи старее пересчитываются
  static const int analyzerVersion = 2;

  /// Кратко о том, что проверять в [flags]
  static const flagPartial = 'partial'; // разобраны только отрывки трека
  static const flagShort = 'short'; // мало звучащего материала
  static const flagNoRhythm = 'no_rhythm'; // темп не найден
  static const flagWeakKey = 'weak_key'; // тональность неуверенная
  static const flagNoLoudness = 'no_loudness'; // громкость (LUFS) не измерена
  static const flagDecodeGap = 'decode_gap'; // декодер отдал заметно меньше звука, чем длится трек
  static const flagPhraseGuess = 'phrase_guess'; // длина фразы предположена
  static const flagVocalHeuristic = 'vocal_heuristic'; // кривая вокала — эвристика

  final String trackId;

  /// Версия содержимого файла (контрольная сумма или «изменён:размер»): изменился файл — запись устарела
  final String revision;
  final int schema;
  final int analyzer;

  /// 'full' — весь трек, 'fast' — четыре отрывка
  final String mode;
  final int analyzedAt; // мс с 1970 (UTC)

  /// Длительность трека и сколько секунд звука действительно разобрано
  final double durationSec;
  final double coverageSec;

  // Ритм
  final double? bpm;
  final double bpmConf; // 0…1; от ≈0,1 темп можно считать найденным
  final double tempoStability; // 0…1: насколько отрезки трека согласны с общим темпом
  final double onsetDensity; // атак в секунду по всему разобранному звуку

  // Гармония
  final String? key; // Camelot, например «8A»
  final double keyConf; // −1…1, надёжной считаем от 0,5
  final List<double> chroma; // 12 значений, сумма 1

  // Тембр
  final List<double> mfccMean; // 12
  final List<double> mfccStd; // 12
  final double centroidMean, centroidStd, rolloffMean, rolloffStd, flatnessMean, flatnessStd;
  final List<double> contrast; // 6

  // Энергия и динамика
  final double rmsDb; // средняя громкость звучащих кадров
  final double dynamicRangeDb; // 95-й минус 10-й процентиль громкости кадров
  final double bassRatio; // доля баса 20–150 Гц
  final double midRatio; // доля средних частот 300–3400 Гц
  final double energyStdDb; // изменчивость громкости по ходу трека
  final double timbreDrift; // насколько тембр конца трека отличается от начала
  final double? lufs; // интегральная громкость по BS.1770, если удалось измерить
  final double? lra; // диапазон громкости, LU

  /// Ширина стерео: RMS бокового канала (L−R)/2 к RMS среднего (L+R)/2, по всему разобранному звуку.
  /// 0 — практически моно, ~0,3–0,6 — типичная поп-запись, выше — сильно разнесённый микс. null — боковой канал
  /// не декодировался (источник сам moно, старый декодер до этой версии анализатора, или сбой ffmpeg — не критично)
  final double? stereoWidth;

  final SectionIndex? sections;
  final SegmentStats? intro;
  final SegmentStats? outro;
  final List<String> flags;
  final DjData? dj;

  const TrackFeatures({
    required this.trackId,
    required this.revision,
    this.schema = schemaVersion,
    this.analyzer = analyzerVersion,
    required this.mode,
    required this.analyzedAt,
    required this.durationSec,
    required this.coverageSec,
    this.bpm,
    this.bpmConf = 0,
    this.tempoStability = 0,
    this.onsetDensity = 0,
    this.key,
    this.keyConf = 0,
    required this.chroma,
    required this.mfccMean,
    required this.mfccStd,
    required this.centroidMean,
    required this.centroidStd,
    required this.rolloffMean,
    required this.rolloffStd,
    required this.flatnessMean,
    required this.flatnessStd,
    required this.contrast,
    required this.rmsDb,
    required this.dynamicRangeDb,
    required this.bassRatio,
    required this.midRatio,
    required this.energyStdDb,
    required this.timbreDrift,
    this.lufs,
    this.lra,
    this.stereoWidth,
    this.sections,
    this.intro,
    this.outro,
    this.flags = const [],
    this.dj,
  });

  bool get tempoReliable => bpm != null && bpmConf >= 0.1;
  bool get keyReliable => key != null && keyConf >= 0.5;

  /// Доля трека, которая разобрана, 0…1
  double get coverage => durationSec <= 0 ? 0.0 : (coverageSec / durationSec).clamp(0.0, 1.0).toDouble();

  bool hasFlag(String f) => flags.contains(f);

  /// Legacy v1 stays usable while the richer analyzer upgrades it in background.
  bool isCompatibleFor(String rev) => revision == rev && schema == schemaVersion && analyzer >= 1;

  /// Запись соответствует текущему файлу и текущему анализатору
  bool isCurrentFor(String rev) => revision == rev && schema == schemaVersion && analyzer >= analyzerVersion;

  /// Какая из двух записей одного трека лучше: для слияния данных от разных устройств.
  /// Порядок: совпадает с нужной версией файла → новее схема → новее анализатор → полный разбор → больше покрытие → новее по времени → по id (для стабильности)
  static int compare(TrackFeatures a, TrackFeatures b, {String? wantRevision}) {
    if (wantRevision != null) {
      final ca = a.revision == wantRevision ? 1 : 0;
      final cb = b.revision == wantRevision ? 1 : 0;
      if (ca != cb) return ca.compareTo(cb);
    }
    if (a.schema != b.schema) return a.schema.compareTo(b.schema);
    if (a.analyzer != b.analyzer) return a.analyzer.compareTo(b.analyzer);
    final fa = a.mode == 'full' ? 1 : 0;
    final fb = b.mode == 'full' ? 1 : 0;
    if (fa != fb) return fa.compareTo(fb);
    final cov = a.coverageSec.compareTo(b.coverageSec);
    if (cov != 0 && (a.coverageSec - b.coverageSec).abs() > 5) return cov;
    if (a.analyzedAt != b.analyzedAt) return a.analyzedAt.compareTo(b.analyzedAt);
    return a.revision.compareTo(b.revision);
  }

  Map<String, dynamic> toJson() => {
        'id': trackId,
        'rev': revision,
        'sv': schema,
        'av': analyzer,
        'md': mode,
        'at': analyzedAt,
        'dur': _r(durationSec, 1),
        'cov': _r(coverageSec, 1),
        if (bpm != null) 'bpm': _r(bpm!, 2),
        'bc': _r(bpmConf, 2),
        'bs': _r(tempoStability, 2),
        'od': _r(onsetDensity, 2),
        if (key != null) 'key': key,
        'kc': _r(keyConf, 2),
        'ch': _rl(chroma, 3),
        'mm': _rl(mfccMean, 2),
        'ms': _rl(mfccStd, 2),
        'sp': _rl([centroidMean, centroidStd, rolloffMean, rolloffStd, flatnessMean, flatnessStd], 3),
        'ct': _rl(contrast, 2),
        'en': _rl([rmsDb, dynamicRangeDb, bassRatio, midRatio, energyStdDb, timbreDrift], 3),
        if (lufs != null) 'lu': _r(lufs!, 1),
        if (lra != null) 'lr': _r(lra!, 1),
        if (stereoWidth != null) 'sw': _r(stereoWidth!, 3),
        if (sections != null) 'sx': sections!.toJson(),
        if (intro != null) 'in': intro!.toJson(),
        if (outro != null) 'out': outro!.toJson(),
        if (flags.isNotEmpty) 'q': flags,
        if (dj != null) 'dj': dj!.toJson(),
      };

  /// Читает запись; null — запись повреждена или не наша (без id, версии файла или обязательных массивов)
  static TrackFeatures? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final rev = j['rev'];
    if (id is! String || id.isEmpty || rev is! String) return null;
    final ch = j['ch'], mm = j['mm'], ms = j['ms'], sp = j['sp'], ct = j['ct'], en = j['en'];
    if (ch is! List || ch.length != 12 || mm is! List || mm.length != 12 || ms is! List || ms.length != 12) return null;
    if (sp is! List || sp.length != 6 || ct is! List || ct.length != 6 || en is! List || en.length != 6) return null;
    try {
      final spv = _dl(sp, 6), env = _dl(en, 6);
      final q = j['q'];
      return TrackFeatures(
        trackId: id,
        revision: rev,
        schema: _in(j['sv']) ?? 0,
        analyzer: _in(j['av']) ?? 0,
        mode: (j['md'] as String?) ?? 'fast',
        analyzedAt: _in(j['at']) ?? 0,
        durationSec: _d(j['dur']),
        coverageSec: _d(j['cov']),
        bpm: _dn(j['bpm']),
        bpmConf: _d(j['bc']),
        tempoStability: _d(j['bs']),
        onsetDensity: _d(j['od']),
        key: j['key'] as String?,
        keyConf: _d(j['kc']),
        chroma: _dl(ch, 12),
        mfccMean: _dl(mm, 12),
        mfccStd: _dl(ms, 12),
        centroidMean: spv[0],
        centroidStd: spv[1],
        rolloffMean: spv[2],
        rolloffStd: spv[3],
        flatnessMean: spv[4],
        flatnessStd: spv[5],
        contrast: _dl(ct, 6),
        rmsDb: env[0],
        dynamicRangeDb: env[1],
        bassRatio: env[2],
        midRatio: env[3],
        energyStdDb: env[4],
        timbreDrift: env[5],
        lufs: _dn(j['lu']),
        lra: _dn(j['lr']),
        stereoWidth: _dn(j['sw']),
        sections: SectionIndex.fromJson(j['sx']),
        intro: SegmentStats.fromJson(j['in']),
        outro: SegmentStats.fromJson(j['out']),
        flags: q is List ? [for (final x in q) '$x'] : const [],
        dj: DjData.fromJson(j['dj']),
      );
    } catch (_) {
      return null;
    }
  }
}
