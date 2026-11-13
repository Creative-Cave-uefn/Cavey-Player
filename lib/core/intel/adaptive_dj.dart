import 'dart:math' as math;
import 'dart:typed_data';

import '../automix.dart';
import '../dj.dart';
import 'dj_plan.dart';
import 'record.dart';

enum AdaptiveTechnique { autoMix, beatBlend, shortFade, cut }

class AdaptiveTrack {
  final String id;
  final MixProfile? profile;
  final TrackFeatures? features;
  final String artist;
  const AdaptiveTrack(this.id, this.profile, this.features, {this.artist = ''});

  bool get reliable {
    final p = profile, f = features;
    if (p == null || f == null) return false;
    return f.schema == TrackFeatures.schemaVersion && f.analyzer >= 1 &&
        f.mode == 'full' && f.coverageSec.isFinite && f.durationSec.isFinite && f.coverage >= 0.9 && !f.hasFlag(TrackFeatures.flagDecodeGap) &&
        !f.hasFlag(TrackFeatures.flagShort) && p.durationMs > 15000 && p.endMs <= p.durationMs &&
        p.endMs > p.introMs + 10000 && p.introMs >= 0 && p.loudDb.isFinite &&
        (p.bpm == null || (p.bpm!.isFinite && p.bpm! > 0)) &&
        (f.durationSec * 1000 - p.durationMs).abs() <= 4000 &&
        _validSegment(f.intro) && _validSegment(f.outro);
  }

  /// Envelope and grid have separate jobs. Use the full intelligence grid for
  /// both decks instead of demanding agreement with a second beat estimator.
  MixProfile get planningProfile {
    final p = profile!, g = features?.dj;
    if (g == null) return p;
    return MixProfile(durationMs: p.durationMs, introMs: p.introMs, outroMs: p.outroMs,
        endMs: p.endMs, loudDb: p.loudDb, v: p.v, bpm: g.gridBpm,
        headBeatMs: g.headBeatMs ?? g.firstBeatMs, tailBeatMs: g.tailBeatMs,
        headBarMs: g.headBarMs, tailBarMs: g.tailBarMs,
        key: features?.keyReliable == true ? features!.key : p.key, wave: p.wave, genre: p.genre);
  }

  String get analysisStatus {
    final p = profile, f = features;
    if (p == null) return 'нет профиля громкости';
    if (f == null) return 'нет актуального полного Audio Intelligence';
    if (f.mode != 'full') return 'быстрый анализ: нужен полный';
    if (f.coverage < 0.9) return 'разобрано менее 90% трека';
    if (!reliable) return 'анализ неполный или не совпадает с файлом';
    return 'анализ готов';
  }

  static bool _validSegment(SegmentStats? s) => s != null && s.energyDb.isFinite &&
      s.centroidHz.isFinite && s.centroidHz >= 0 && s.bassRatio.isFinite && s.onsetDensity.isFinite;
}

class AdaptiveDecision {
  final String to;
  final MixPlan? plan;
  final AdaptiveTechnique technique;
  final double score;
  final List<String> reasons;
  final List<String> path;
  final List<Map<String, Object?>> alternatives;
  const AdaptiveDecision(this.to, this.plan, this.technique, this.score, this.reasons,
      {this.path = const [], this.alternatives = const []});
  Map<String, Object?> toJson() => {
    'to': to, 'technique': technique.name, 'score': score, 'reasons': reasons, 'path': path,
    'alternatives': alternatives,
    'outMs': plan?.start.inMilliseconds, 'inMs': plan?.inStart.inMilliseconds,
    'lengthMs': plan?.length.inMilliseconds, 'rate': plan?.rate,
  };
}

/// Section compatibility is separate from discovery similarity. No BPM/key veto.
/// Only already analysed tracks in the supplied queue window may be reordered.
class AdaptiveDj {
  static const maxCandidates = 5;
  static const horizon = 3;
  static const beamWidth = 6;

  static AdaptiveDecision fallback(AdaptiveTrack from, AdaptiveTrack next, int maxSec) {
    final a = from.profile, b = next.profile;
    return AdaptiveDecision(next.id, a != null && b != null && a.endMs > a.introMs + 10000
        ? MixPlan.make(a, b, maxSec: maxSec) : null,
        AdaptiveTechnique.autoMix, 0, ['AutoMix: ${from.id} — ${from.analysisStatus}; ${next.id} — ${next.analysisStatus}']);
  }

  static AdaptiveDecision choose(AdaptiveTrack from, List<AdaptiveTrack> pool,
      {DjMix options = const DjMix(), int maxSec = 8, int earliestMs = 0, bool allowCut = true}) {
    if (pool.isEmpty) throw ArgumentError('Empty candidate pool');
    final candidates = pool.where((t) => t.id != from.id).take(maxCandidates).toList();
    if (!from.reliable || candidates.isEmpty) return fallback(from, pool.first, maxSec);
    var beam = <_Path>[_Path(from, const [], const [], 0)];
    for (var depth = 0; depth < math.min(horizon, candidates.length); depth++) {
      final expanded = <_Path>[];
      for (final path in beam) {
        for (final next in candidates) {
          if (path.ids.contains(next.id) || !next.reliable) continue;
          final decision = pair(path.last, next, options: options, maxSec: maxSec,
              earliestMs: depth == 0 ? earliestMs : 0, allowCut: allowCut);
          if (decision.technique == AdaptiveTechnique.autoMix) continue;
          final repeat = next.artist.isNotEmpty && next.artist == path.last.artist ? 0.12 : 0.0;
          final repeatedTechnique = path.decisions.isNotEmpty && path.decisions.last.technique == decision.technique ? 0.025 : 0.0;
          expanded.add(_Path(next, [...path.ids, next.id], [...path.decisions, decision],
              path.score + math.pow(0.7, depth) * (decision.score - repeat - repeatedTechnique)));
        }
      }
      if (expanded.isEmpty) break;
      expanded.sort((a, b) {
        final order = b.score.compareTo(a.score);
        return order != 0 ? order : a.ids.join('|').compareTo(b.ids.join('|'));
      });
      beam = expanded.take(beamWidth).toList();
    }
    final best = beam.first;
    if (best.decisions.isEmpty) return fallback(from, pool.first, maxSec);
    final first = best.decisions.first;
    return AdaptiveDecision(first.to, first.plan, first.technique, first.score, first.reasons,
        path: best.ids, alternatives: [
          for (final next in candidates)
            pair(from, next, options: options, maxSec: maxSec, earliestMs: earliestMs, allowCut: allowCut).toJson(),
        ]);
  }

  static AdaptiveDecision pair(AdaptiveTrack from, AdaptiveTrack next,
      {DjMix options = const DjMix(), int maxSec = 8, int earliestMs = 0, bool allowCut = true}) {
    if (!from.reliable || !next.reliable) return fallback(from, next, maxSec);
    final a = from.planningProfile, b = next.planningProfile, fa = from.features!, fb = next.features!;
    final da = fa.dj, db = fb.dj;
    final normal = MixPlan.make(a, b, maxSec: maxSec);
    var plan = MixPlan.make(a, b, maxSec: maxSec,
        dj: _gridReady(from) && _gridReady(next) ? options : null);
    if (plan.dj) plan = DjPlanner.refine(plan, a, b, fa, fb, allowCut: false).plan;
    var technique = plan.dj ? AdaptiveTechnique.beatBlend : AdaptiveTechnique.shortFade;
    final notes = <String>[];
    // Compare candidate phrase regions in the outgoing tail and incoming head.
    // Curves are indexed in source time; incoming overlap consumes length * rate.
    final exits = <int>{plan.start.inMilliseconds};
    if (da != null && da.phraseConf >= 0.3) {
      exits.addAll(da.phrasesMs.where((p) => p >= a.endMs - 45000 && p >= a.introMs + 10000 && p <= a.endMs - 1000));
    }
    final entries = <int>{plan.inStart.inMilliseconds};
    if (db != null && db.phraseConf >= 0.3) {
      entries.addAll(db.phrasesMs.where((p) => p >= b.introMs && p <= 12000));
    }
    var best = double.negativeInfinity;
    MixPlan? bestPlan;
    var bestRisk = false;
    var bestUnknown = false;
    for (final exit in exits) {
      if (exit < earliestMs || exit < 0) continue;
      for (final enter in entries) {
        var len = math.min(plan.length.inMilliseconds, a.endMs - exit);
        len = math.min(len, ((b.endMs - enter) / plan.rate).floor());
        if (!plan.dj) len = math.min(len, 2500);
        if (len < 200) continue;
        final va = _vocal(da?.vocalCurve, exit, len);
        final vb = _vocal(db?.vocalCurve, enter, (len * plan.rate).ceil());
        // A v1 midrange proxy is NOT a calibrated vocal probability. It may
        // shorten a risky overlay, but cannot establish that vocals are absent.
        final risk = va != null && vb != null && va >= 0.65 && vb >= 0.65;
        final unknownVocal = va == null || vb == null;
        if (risk || unknownVocal) len = math.min(len, 2000);
        final energyA = _curve(da?.energyCurve, exit, fa.outro!.energyDb + 100);
        final energyB = _curve(db?.energyCurve, enter, fb.intro!.energyDb + 100);
        final energy = math.exp(-(energyA - energyB).abs() / 12);
        final spectral = math.exp(-(fa.outro!.centroidHz - fb.intro!.centroidHz).abs() / 3000);
        final bass = 1 - (fa.outro!.bassRatio - fb.intro!.bassRatio).abs().clamp(0.0, 1.0);
        final score = 0.48 * energy + 0.22 * spectral + 0.15 * bass +
            (plan.dj ? 0.1 : 0.06) +
            (da != null && da.phraseConf >= 0.3 && da.phrasesMs.contains(exit) ? 0.05 : 0) - (risk ? 0.14 : 0) - (unknownVocal ? 0.06 : 0) -
            (a.endMs - exit - len).abs() / 300000;
        if (score <= best) continue;
        best = score;
        bestRisk = risk;
        bestUnknown = unknownVocal;
        final keepBeat = plan.dj && !risk && !unknownVocal;
        bestPlan = MixPlan(Duration(milliseconds: exit), Duration(milliseconds: len),
            Duration(milliseconds: enter), plan.inGain,
            dj: keepBeat, rate: keepBeat ? plan.rate : 1,
            grid: keepBeat ? plan.grid : null,
            swapAt: keepBeat && plan.swapAt != null && plan.swapAt! < Duration(milliseconds: len) ? plan.swapAt : null,
            offsetMs: keepBeat ? plan.offsetMs : 0,
            preroll: keepBeat ? Duration(milliseconds: math.min(700, (enter / plan.rate).floor())) : Duration.zero);
      }
    }
    if (bestPlan == null) {
      // Too late to schedule the computed regions: preserve the queue and AutoMix.
      return AdaptiveDecision(next.id, normal, AdaptiveTechnique.autoMix, 0, const ['Нет доступной точки перехода впереди']);
    }
    plan = bestPlan;
    technique = plan.dj ? AdaptiveTechnique.beatBlend : AdaptiveTechnique.shortFade;
    final contrastCut = a.bpm != null && b.bpm != null &&
        bpmStretch(a.bpm!, b.bpm!) > options.range &&
        fa.outro!.onsetDensity >= 1.2 && fb.intro!.onsetDensity >= 1.2 &&
        (fa.outro!.energyDb - fb.intro!.energyDb).abs() < 6;
    if (bestRisk) {
      notes.add('Риск двух голосов по эвристике: длинное наложение запрещено');
    }
    if (allowCut && (bestRisk || contrastCut) && da != null && da.phraseConf >= 0.5 &&
        da.phrasesMs.contains(plan.start.inMilliseconds)) {
      technique = AdaptiveTechnique.cut;
      plan = MixPlan(plan.start, const Duration(milliseconds: 250), plan.inStart, plan.inGain);
      if (contrastCut) notes.add('Контрастный темп: короткий стык на границе фразы');
    }
    if (bestUnknown) notes.add('Вокал не определён: только короткое наложение');
    if (!plan.dj && !bestRisk && !bestUnknown) {
      notes.add(!_gridReady(from) || !_gridReady(next)
          ? 'Сетка полного анализа нестабильна или неполна: короткий переход'
          : 'Подгонка темпа превышает настройку: короткий переход');
    }
    notes.add('Совместимость участков: энергия, спектр, бас; BPM/тональность не исключают трек');
    return AdaptiveDecision(next.id, plan, technique, best.clamp(0.0, 1.0).toDouble(), notes);
  }

  static bool _gridReady(AdaptiveTrack track) {
    final f = track.features!, g = f.dj, bpm = g?.gridBpm;
    return g != null && g.gridStable && f.tempoReliable && f.tempoStability >= 0.7 &&
        bpm != null && bpm.isFinite && bpm >= 60 && bpm <= 200 &&
        (g.headBeatMs ?? g.firstBeatMs) != null && g.tailBeatMs != null;
  }

  static double _curve(Uint8List? curve, int at, double fallback) =>
      curve == null || at < 0 || at ~/ 1000 >= curve.length ? fallback : curve[at ~/ 1000].toDouble();

  static double? _vocal(Uint8List? curve, int at, int len) {
    final start = at ~/ 1000, end = ((at + len) / 1000).ceil();
    if (curve == null || start < 0 || end > curve.length || end <= start) return null;
    var sum = 0;
    for (var i = start; i < end; i++) { sum += curve[i]; }
    return sum / (end - start) / 100;
  }
}

class _Path {
  final AdaptiveTrack last;
  final List<String> ids;
  final List<AdaptiveDecision> decisions;
  final double score;
  const _Path(this.last, this.ids, this.decisions, this.score);
}
