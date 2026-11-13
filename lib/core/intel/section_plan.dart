import 'dart:math' as math;
import '../automix.dart';
import 'record.dart';
import 'sections.dart';
import 'rhythm.dart';
import 'vocal_activity.dart';

class SectionProposal {
  final MixPlan plan;
  final String technique;
  final double score;
  final Map<String, double> components;
  final List<String> reasons;
  const SectionProposal(
      this.plan, this.technique, this.score, this.components, this.reasons);
}

/// Joint cue/length/technique search, bounded to 8 exits x 6 entries.
/// No global genre veto, no invented section function or vocal certainty.
class SectionPlanner {
  static SectionProposal? plan(
      MixProfile a, MixProfile b, TrackFeatures fa, TrackFeatures fb,
      {required DjMix options,
      required bool beatAllowed,
      int earliestMs = 0,
      int? manualPositionMs,
      bool allowCut = false}) {
    final sa = fa.sections, sb = fb.sections;
    if (sa == null || sb == null) return null;
    final beat = beatAllowed ? MixPlan.make(a, b, dj: options) : null;
    final matched = beat?.dj == true;
    final earliest =
        math.max(earliestMs, math.max(a.introMs + 10000, a.endMs - 60000));
    final exits = manualPositionMs == null
        ? _cues(
            sa, fa.dj, earliest, a.endMs - 300, a.endMs - 2500, 8, fa.rhythm)
        : <int>{
            manualPositionMs + 750,
            ...?fa.rhythm
                ?.cues(manualPositionMs + 750,
                    math.min(a.endMs - 300, manualPositionMs + 2500))
                .take(3),
            if (matched &&
                a.bpm != null &&
                (a.tailBarMs ?? a.tailBeatMs) != null)
              ((a.tailBarMs ?? a.tailBeatMs)! +
                      ((manualPositionMs +
                                      750 -
                                      (a.tailBarMs ?? a.tailBeatMs)!) /
                                  (4 * 60000 / a.bpm!))
                              .ceil() *
                          (4 * 60000 / a.bpm!))
                  .round(),
          }.where((p) => p >= manualPositionMs && p < a.endMs - 300).toList();
    final entries = _cues(sb, fb.dj, b.introMs, math.min(b.endMs - 1000, 24000),
        b.introMs, 6, fb.rhythm);
    final cacheA = <String, AudioRegion?>{}, cacheB = <String, AudioRegion?>{};
    AudioRegion? region(SectionIndex index, Map<String, AudioRegion?> cache,
        int start, int length) {
      final key = '$start:$length';
      if (!cache.containsKey(key)) cache[key] = index.at(start, length);
      return cache[key];
    }

    SectionProposal? best;
    for (final exit in exits) {
      for (final enter in entries) {
        final templates =
            <(String, int, double, (double, double, double, double)?)>[
          ('shortFade', 2000, 1, null),
          if (allowCut) ('cut', 250, 1, null),
          ('atmospheric', 6000, 1, null),
          for (final bars in [1, 2, 4, 8])
            if (bars <= options.bars)
              if (fa.rhythm != null && fb.rhythm != null)
                ..._localTemplate(fa.rhythm!, fb.rhythm!, exit, enter, bars * 4,
                    options.range)
              else if (matched)
                (
                  'beatBlend',
                  (bars * 4 * 60000 / a.bpm!).round(),
                  beat!.rate,
                  beat.grid
                ),
        ];
        for (final (kind, wanted, rate, grid) in templates) {
          final len = math.min(wanted,
              math.min(a.endMs - exit, ((b.endMs - enter) / rate).floor()));
          if (len < 200 || (kind == 'beatBlend' && len < wanted)) continue;
          final incomingMs = (len * rate).ceil();
          // Statistics must describe the actual audible window. A cut uses a
          // short inspection window on either side, not just a single sample.
          final inspect = kind == 'cut' ? 1000 : len;
          final ra = region(sa, cacheA,
              math.max(a.introMs, exit - (kind == 'cut' ? 500 : 0)), inspect);
          final rb =
              region(sb, cacheB, enter, kind == 'cut' ? 1000 : incomingMs);
          if (ra == null ||
              rb == null ||
              ra.activeFraction < 0.35 ||
              rb.activeFraction < 0.35) continue;
          final isBeat = kind == 'beatBlend';
          final boundaryA =
              math.max(sa.confidenceAt(exit), _phraseConfidence(fa.dj, exit));
          final boundaryB =
              math.max(sb.confidenceAt(enter), _phraseConfidence(fb.dj, enter));
          if (kind == 'cut' && (boundaryA < 0.4 || boundaryB < 0.25)) continue;
          if (isBeat &&
              fa.rhythm == null &&
              (!_onGrid(exit, a.tailBarMs ?? a.tailBeatMs, a.bpm) ||
                  !_onGrid(enter, b.headBarMs ?? b.headBeatMs, b.bpm)))
            continue;
          final voiceA = ra.reliableVocals
              ? ra.vocalProbability
              : _proxy(fa.dj, exit, len);
          final voiceB = rb.reliableVocals
              ? rb.vocalProbability
              : _proxy(fb.dj, enter, incomingMs);
          final measured = ra.reliableVocals && rb.reliableVocals;
          final unknown = voiceA == null || voiceB == null;
          final vocalClash = measured && voiceA! > 0.5 && voiceB! > 0.5;
          final proxyRisk = !measured &&
              voiceA != null &&
              voiceB != null &&
              voiceA > 0.65 &&
              voiceB > 0.65;
          final modelA = fa.vocalActivity?.riskAt(exit, len),
              modelB = fb.vocalActivity?.riskAt(enter, incomingMs);
          final collision = fa.vocalActivity == null || fb.vocalActivity == null
              ? null
              : VocalActivity.collision(
                  fa.vocalActivity!, fb.vocalActivity!, exit, enter, len, rate);
          final modelClash = collision?.risky == true;
          if (len > 2000 && (vocalClash || modelClash)) continue;
          // Low event scores do not certify absence. Limit uncertain experiments.
          if (!measured &&
              len > (modelA != null && modelB != null ? 8000 : 4000)) continue;
          if (len > 2000 &&
              unknown &&
              modelA == null &&
              modelB == null &&
              !isBeat) continue;
          if (kind == 'atmospheric' &&
              (ra.onsetDensity > 1 ||
                  rb.onsetDensity > 1 ||
                  ra.bassRatio > 0.5 ||
                  rb.bassRatio > 0.5)) continue;
          final energy = math.exp(-(ra.energyDb - rb.energyDb).abs() / 10);
          final spectral =
              math.exp(-(ra.centroidHz - rb.centroidHz).abs() / 2500);
          var timbreDistance = 0.0;
          for (var k = 0; k < 12; k++) {
            timbreDistance += math.pow(ra.mfcc[k] - rb.mfcc[k], 2);
          }
          final timbre = math.exp(-math.sqrt(timbreDistance / 12) / 16);
          final harmonic = _cosine(ra.chroma, rb.chroma);
          final rhythm =
              math.exp(-(ra.onsetDensity - rb.onsetDensity).abs() / 2);
          final wa = fa.rhythm?.at(exit, len),
              wb = fb.rhythm?.at(enter, incomingMs);
          final groove = wa != null && wb != null
              ? grooveSimilarity(wa.groove, wb.groove)
              : 0.5;
          final kickPattern = wa != null && wb != null
              ? grooveSimilarity(wa.lowGroove, wb.lowGroove)
              : 0.5;
          final attackTone = ra.attackCentroidHz != null &&
                  rb.attackCentroidHz != null
              ? math.exp(-(ra.attackCentroidHz! - rb.attackCentroidHz!).abs() /
                      1800) *
                  math.exp(-((ra.attackBassRatio ?? ra.bassRatio) -
                              (rb.attackBassRatio ?? rb.bassRatio))
                          .abs() *
                      3)
              : 0.5;
          if (isBeat &&
              len > 8000 &&
              wa != null &&
              wb != null &&
              (groove < 0.65 || kickPattern < 0.55 || attackTone < 0.35))
            continue;
          final bass = (1 - (ra.bassRatio - rb.bassRatio).abs())
              .clamp(0.0, 1.0)
              .toDouble();
          final stretch = (rate - 1).abs() / math.max(0.01, options.range);
          final discardedTail = (a.endMs - exit - len).clamp(0, 60000);
          final peakA = ra.samplePeakDb, peakB = rb.samplePeakDb;
          // Conservative mono source peak bound, not a stereo true-peak meter.
          final peakBound = peakA == null || peakB == null
              ? null
              : 20 *
                  math.log(
                      math.pow(10, peakA / 20) + math.pow(10, peakB / 20)) /
                  math.ln10;
          final peakPenalty = kind == 'cut'
              ? 0.0
              : peakBound == null
                  ? 0.03
                  : math.max(0.0, peakBound + 1) / 30;
          final components = <String, double>{
            'energy': energy,
            'spectral': spectral,
            'timbre': timbre,
            'harmony': harmonic,
            'rhythm': rhythm,
            'bass': bass,
            'boundary': (boundaryA + boundaryB) / 2,
            'groove': groove,
            'kickPattern': kickPattern,
            'attackTone': attackTone,
            if (wa != null && wb != null)
              'localRhythmResidualMs': math.max(wa.residualMs, wb.residualMs),
            'stretchCost': stretch,
            'vocalRisk': vocalClash || modelClash
                ? 1
                : measured
                    ? 0
                    : proxyRisk
                        ? 0.6
                        : 0.5,
            if (modelA != null) 'voiceModelOut': modelA,
            if (modelB != null) 'voiceModelIn': modelB,
            if (collision != null)
              'concurrentVoiceMs': collision.concurrentMs.toDouble(),
            if (collision != null)
              'longestVoiceRunMs': collision.longestRunMs.toDouble(),
            'peakPenalty': peakPenalty,
            'discardedTailMs': discardedTail.toDouble()
          };
          final score = 0.18 * energy +
              0.1 * spectral +
              0.14 * timbre +
              0.08 * harmonic +
              0.06 * rhythm +
              0.06 * bass +
              0.12 * components['boundary']! +
              0.07 * groove +
              0.05 * kickPattern +
              0.06 * attackTone +
              (isBeat
                  ? 0.08
                  : kind == 'atmospheric'
                      ? 0.04
                      : 0) -
              0.06 * stretch -
              peakPenalty -
              (vocalClash || modelClash
                  ? 0.1
                  : proxyRisk
                      ? 0.05
                      : unknown
                          ? 0.06
                          : 0) -
              discardedTail / 300000 -
              (kind == 'cut'
                  ? 0.045
                  : kind == 'shortFade'
                      ? 0.02
                      : 0);
          if (best != null && score <= best.score) continue;
          Duration? swap;
          if (isBeat && options.bass && grid != null) {
            final bar = 4 * grid.$2;
            final middleBar = ((len / 2) / bar).round();
            final at = (math.max(1, middleBar) * bar).round();
            if (at > 0 && at < len) swap = Duration(milliseconds: at);
          }
          final gain = math
              .pow(10, (ra.energyDb - rb.energyDb).clamp(-6.0, 6.0) / 20)
              .toDouble();
          final p = MixPlan(Duration(milliseconds: exit),
              Duration(milliseconds: len), Duration(milliseconds: enter), gain,
              dj: isBeat,
              rate: rate,
              grid: grid,
              offsetMs: isBeat ? options.offsetMs : 0,
              swapAt: swap,
              preroll: isBeat
                  ? Duration(
                      milliseconds: math.min(700, (enter / rate).floor()))
                  : Duration.zero);
          best = SectionProposal(
              p, kind, score.clamp(0.0, 1.0).toDouble(), components, [
            'Локальные участки: $exit → $enter мс; ${len / 1000} с',
            'Энергия/тембр/гармония/ритм оценены в выбранных окнах',
            if (wa != null && wb != null)
              'Локальные атаки и groove; размер такта не определён',
            measured
                ? 'Есть независимые данные о вокале'
                : modelA != null && modelB != null
                    ? 'YAMNet: риск голоса, отсутствие вокала не подтверждено'
                    : 'Вокал не подтверждён: ограниченная длина наложения',
            if (vocalClash || modelClash)
              'Наложение голосов запрещает длинный blend',
            if (peakBound != null)
              'Консервативная оценка пика исходного mono: ${peakBound.toStringAsFixed(1)} dBFS',
          ]);
        }
      }
    }
    return best;
  }

  static List<int> _cues(SectionIndex sx, DjData? dj, int from, int to,
      int preferred, int limit, RhythmTimeline? timeline) {
    if (to < from) return const [];
    final candidates = <int>{
      preferred.clamp(from, to).toInt(),
      ...sx.boundaries(fromMs: from, toMs: to)
    };
    if (dj != null && dj.phraseConf >= 0.2)
      candidates.addAll(dj.phrasesMs.where((p) => p >= from && p <= to));
    // Also expose bar-aligned candidates: a novelty window need not land on a beat.
    final bpm = dj?.gridBpm, anchor = dj?.barAnchorMs ?? dj?.firstBeatMs;
    if (dj?.gridStable == true &&
        bpm != null &&
        anchor != null &&
        bpm.isFinite &&
        bpm > 0) {
      final bar = 4 * 60000 / bpm;
      final k = ((preferred - anchor) / bar).floor();
      for (var d = -3; d <= 3; d++) {
        final p = (anchor + (k + d) * bar).round();
        if (p >= from && p <= to) candidates.add(p);
      }
    }
    final sorted = candidates.toList()
      ..sort((a, b) {
        final qa = math.max(sx.confidenceAt(a), _phraseConfidence(dj, a)) -
            (a - preferred).abs() / 200000;
        final qb = math.max(sx.confidenceAt(b), _phraseConfidence(dj, b)) -
            (b - preferred).abs() / 200000;
        final score = qb.compareTo(qa);
        return score != 0 ? score : a.compareTo(b);
      });
    if (timeline == null) return sorted.take(limit).toList();
    final pulses = timeline.cues(from, to), anchors = <int>{};
    for (final target in [preferred, to - 8000, to - 16000, from]) {
      if (pulses.isEmpty) break;
      anchors.add(pulses
          .reduce((a, b) => (a - target).abs() <= (b - target).abs() ? a : b));
    }
    return <int>{...anchors, ...sorted}.take(limit).toList();
  }

  static List<(String, int, double, (double, double, double, double)?)>
      _localTemplate(RhythmTimeline a, RhythmTimeline b, int exit, int enter,
          int pulses, double range) {
    (String, int, double, (double, double, double, double)?)? best;
    var residual = double.infinity;
    for (final wa in a.windows) {
      if (!wa.reliable || exit < wa.startMs || !wa.onBeat(exit)) continue;
      final len = (pulses * 60000 / wa.bpm).round();
      if (exit + len > wa.endMs) continue;
      for (final wb in b.windows) {
        if (!wb.reliable || enter < wb.startMs || !wb.onBeat(enter)) continue;
        var rate = double.infinity;
        for (final factor in [0.5, 1.0, 2.0]) {
          final candidate = wa.bpm * factor / wb.bpm;
          if ((candidate - 1).abs() < (rate - 1).abs()) rate = candidate;
        }
        if ((rate - 1).abs() > range || enter + (len * rate).ceil() > wb.endMs)
          continue;
        final error = wa.residualMs + wb.residualMs;
        if (error >= residual) continue;
        residual = error;
        best = (
          'beatBlend',
          len,
          rate,
          (exit.toDouble(), 60000 / wa.bpm, enter.toDouble(), 60000 / wb.bpm)
        );
      }
    }
    return best == null ? const [] : [best];
  }

  static double _phraseConfidence(DjData? d, int at) =>
      d != null && d.phrasesMs.any((p) => (p - at).abs() <= 50)
          ? d.phraseConf
          : 0;
  static bool _onGrid(int at, int? anchor, double? bpm) {
    if (anchor == null || bpm == null || !bpm.isFinite || bpm <= 0)
      return false;
    final bar = 4 * 60000 / bpm;
    final phase = ((at - anchor) % bar).abs();
    return math.min(phase, bar - phase) <= 50;
  }

  static double _cosine(List<double> a, List<double> b) {
    var dot = 0.0, aa = 0.0, bb = 0.0;
    for (var i = 0; i < 12; i++) {
      dot += a[i] * b[i];
      aa += a[i] * a[i];
      bb += b[i] * b[i];
    }
    return aa > 0 && bb > 0
        ? (dot / math.sqrt(aa * bb)).clamp(0.0, 1.0).toDouble()
        : 0.5;
  }

  static double? _proxy(DjData? d, int start, int len) {
    final c = d?.vocalCurve,
        a = start ~/ 1000,
        b = ((start + len) / 1000).ceil();
    if (c == null || a < 0 || b > c.length || b <= a) return null;
    var sum = 0;
    for (var i = a; i < b; i++) {
      sum += c[i];
    }
    return sum / (b - a) / 100;
  }
}
