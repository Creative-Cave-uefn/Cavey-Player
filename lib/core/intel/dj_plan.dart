import 'dart:math' as math;
import 'dart:typed_data';

import '../automix.dart';
import 'record.dart';

// Уточнение DJ-перехода по результатам разбора звука (граница фраз, громкость, «вокал»).
//
// Базовый план делает MixPlan: он знает темп, сетку долей и подгоняет темп следующего трека. Здесь он только уточняется:
//  • переход привязывается к границе музыкальной фразы, а не к любому такту: смена идёт там, где музыка и так «переворачивается»;
//  • следующий трек входит на границе своей фразы;
//  • громкость выравнивается по LUFS, если она измерена у обоих треков;
//  • если у обоих треков в месте стыка вокал, наложение укорачивается (или заменяется резким стыком): два голоса поверх друг друга звучат грязно;
//  • резкий стык (hard cut): когда оба трека в этом месте на полной энергии, или вокал мешает, смена делается за полдоли на границе фразы.
// Сдвиги всегда кратны такту базового плана, поэтому фаза доли, найденная в MixAnalyzer, не нарушается.
// Если данных не хватает (нет разбора, сетка нестабильна, фразы не определены), возвращается исходный план без изменений.

enum DjKind { unchanged, blend, cut }

class DjRefine {
  final MixPlan plan;
  final DjKind kind;

  /// Что именно изменено (для журнала)
  final List<String> notes;
  const DjRefine(this.plan, this.kind, this.notes);
}

class DjPlanner {
  /// Вокал на стыке считается мешающим, если у обоих треков он выше этого значения (0…1)
  static const vocalClash = 0.5;

  /// Трек «на полной энергии» в точке, если громкость не ниже его громкого уровня (90-й перцентиль) минус столько дБ
  static const fullEnergyDb = 4.0;

  /// Не больше стольких тактов можно сдвинуть начало перехода к более ранней границе фразы
  static const maxShiftBars = 8;

  static DjRefine refine(MixPlan base, MixProfile out, MixProfile inn, TrackFeatures? fa, TrackFeatures? fb, {bool allowCut = true}) {
    final g = base.grid;
    final da = fa?.dj, db = fb?.dj;
    if (!base.dj || g == null || da == null || db == null || !da.gridStable || !db.gridStable) {
      return DjRefine(base, DjKind.unchanged, const []);
    }
    final beatA = g.$2, beatB = g.$4;
    if (beatA <= 0 || beatB <= 0) return DjRefine(base, DjKind.unchanged, const []);
    final barA = 4 * beatA, barB = 4 * beatB;
    final notes = <String>[];

    final start0 = base.start.inMilliseconds;
    final len0 = base.length.inMilliseconds;
    final enter0 = base.inStart.inMilliseconds;
    final earliest = out.introMs + 10000;

    // --- границы фраз: выход из уходящего трека
    final phrasesA = da.phraseConf >= 0.2 ? da.phrasesMs : const <int>[];
    var start = start0;
    if (phrasesA.isNotEmpty) {
      // Ближайшая сзади (или почти на месте) граница фразы
      int? best;
      for (final p in phrasesA) {
        if (p <= start0 + barA / 2 && p >= start0 - maxShiftBars * barA && p >= earliest) {
          if (best == null || p > best) best = p;
        }
      }
      if (best != null) {
        final bars = ((best - start0) / barA).round();
        if (bars < 0) {
          start = start0 + (bars * barA).round();
          notes.add('начало на границе фразы (${-bars} т. раньше)');
        }
      }
    }

    // --- вход следующего трека на границе его фразы
    final phrasesB = db.phraseConf >= 0.2 ? db.phrasesMs : const <int>[];
    var enter = enter0;
    if (phrasesB.isNotEmpty) {
      int? best;
      var bestD = double.infinity;
      for (final q in phrasesB) {
        final d = (q - enter0).abs().toDouble();
        if (d <= 2 * barB && d < bestD) {
          bestD = d;
          best = q;
        }
      }
      if (best != null) {
        final bars = ((best - enter0) / barB).round();
        final e = enter0 + (bars * barB).round();
        if (bars != 0 && e >= 0 && e <= 12000 && e >= inn.introMs - 300) {
          enter = e;
          notes.add('вход на границе фразы (${bars > 0 ? '+' : ''}$bars т.)');
        }
      }
    }

    var len = len0;
    final rate = base.rate <= 0 ? 1.0 : base.rate;

    // --- вокал и энергия в месте стыка
    final voA = _meanAt(da.vocalCurve, start, len);
    final voB = _meanAt(db.vocalCurve, enter, (len / rate).round());
    final clash = voA != null && voB != null && voA > vocalClash && voB > vocalClash;
    final bothFull = _isFull(da.energyCurve, start) && _isFull(db.energyCurve, enter);

    var kind = DjKind.blend;
    Duration? swapAt = base.swapAt;

    if (allowCut && (clash || bothFull) && len0 >= beatA) {
      // Резкий стык: на границе фразы возле конца запланированного перехода
      var cutAt = start0 + len0;
      if (phrasesA.isNotEmpty) {
        int? best;
        var bestD = double.infinity;
        for (final p in phrasesA) {
          if (p >= earliest && p <= out.endMs - beatA) {
            final d = (p - cutAt).abs().toDouble();
            if (d <= maxShiftBars * barA && d < bestD) {
              bestD = d;
              best = p;
            }
          }
        }
        if (best != null) {
          final bars = ((best - cutAt) / barA).round();
          cutAt += (bars * barA).round();
        }
      }
      if (cutAt <= out.endMs - beatA && cutAt >= earliest) {
        kind = DjKind.cut;
        start = cutAt;
        len = math.max(200, (beatA / 2).round());
        swapAt = null;
        notes.add(clash ? 'резкий стык: вокал мешал бы наложению' : 'резкий стык: оба трека на полной энергии');
      }
    }
    if (kind == DjKind.blend && clash && len > 2 * barA) {
      // Вокал: наложение только на два такта
      final shortLen = (2 * barA).round();
      start = start + (len - shortLen);
      len = shortLen;
      swapAt = base.swapAt == null ? null : Duration(milliseconds: (len / 2).round());
      notes.add('вокал на стыке: наложение сокращено до двух тактов');
    }

    // --- громкость
    var gain = base.inGain;
    final la = fa?.lufs, lb = fb?.lufs;
    if (la != null && lb != null) {
      gain = math.pow(10, (la - lb).clamp(-6.0, 6.0) / 20).toDouble();
      notes.add('громкость по LUFS (${(la - lb).toStringAsFixed(1)} дБ)');
    }

    if (notes.isEmpty) return DjRefine(base, DjKind.unchanged, const []);

    final pre = Duration(milliseconds: math.min(700, (enter / rate).floor()));
    final plan = MixPlan(
      Duration(milliseconds: start),
      Duration(milliseconds: len),
      Duration(milliseconds: enter),
      gain,
      dj: true,
      rate: base.rate,
      swapAt: swapAt,
      grid: base.grid,
      offsetMs: base.offsetMs,
      preroll: pre,
    );
    return DjRefine(plan, kind, notes);
  }

  /// Среднее значение кривой (0…1) на отрезке [fromMs, fromMs + lenMs)
  static double? _meanAt(Uint8List curve, int fromMs, int lenMs) {
    if (curve.isEmpty || lenMs <= 0) return null;
    final a = (fromMs / 1000).floor().clamp(0, curve.length - 1).toInt();
    final b = ((fromMs + lenMs) / 1000).ceil().clamp(a + 1, curve.length).toInt();
    var sum = 0.0;
    for (var i = a; i < b; i++) {
      sum += curve[i];
    }
    return sum / (b - a) / 100.0;
  }

  /// Громкость в момент [atMs] не ниже «громкого» уровня трека (90-й перцентиль) минус [fullEnergyDb]
  static bool _isFull(Uint8List energy, int atMs) {
    if (energy.length < 20) return false;
    final sorted = energy.where((v) => v > 0).toList()..sort();
    if (sorted.isEmpty) return false;
    final high = sorted[((sorted.length - 1) * 0.9).floor()] - 100.0;
    final a = (atMs / 1000).floor().clamp(0, energy.length - 1).toInt();
    // Среднее за три секунды вокруг точки: одна тихая секунда ничего не решает
    var sum = 0.0, n = 0;
    for (var i = math.max(0, a - 1); i <= math.min(energy.length - 1, a + 1); i++) {
      sum += energy[i] - 100.0;
      n++;
    }
    return n > 0 && sum / n >= high - fullEnergyDb;
  }
}
