import 'dart:math' as math;
import '../automix.dart';
import 'record.dart';
import 'sections.dart';

class SectionProposal {
  final MixPlan plan;
  final String technique;
  final double score;
  final Map<String, double> components;
  final List<String> reasons;
  const SectionProposal(this.plan, this.technique, this.score, this.components, this.reasons);
}

/// Joint cue/length/technique search, bounded to 8 exits x 6 entries.
/// No global genre veto, no invented section function or vocal certainty.
class SectionPlanner {
  static SectionProposal? plan(MixProfile a, MixProfile b, TrackFeatures fa, TrackFeatures fb,
      {required DjMix options, required bool beatAllowed, int earliestMs = 0, int? manualPositionMs, bool allowCut = true}) {
    final sa = fa.sections, sb = fb.sections;
    if (sa == null || sb == null) return null;
    final beat = beatAllowed ? MixPlan.make(a, b, dj: options) : null;
    final matched = beat?.dj == true;
    final earliest = math.max(earliestMs, math.max(a.introMs + 10000, a.endMs - 60000));
    final exits = manualPositionMs == null
        ? _cues(sa, fa.dj, earliest, a.endMs - 300, a.endMs - 2500, 8)
        : <int>{manualPositionMs + 750,
            if (matched && a.bpm != null && (a.tailBarMs ?? a.tailBeatMs) != null)
              ((a.tailBarMs ?? a.tailBeatMs)! +
                ((manualPositionMs + 750 - (a.tailBarMs ?? a.tailBeatMs)!) / (4 * 60000 / a.bpm!)).ceil() * (4 * 60000 / a.bpm!)).round(),
          }.where((p) => p >= manualPositionMs && p < a.endMs - 300).toList();
    final entries = _cues(sb, fb.dj, b.introMs, math.min(b.endMs - 1000, 24000), b.introMs, 6);
    final cacheA = <String, AudioRegion?>{}, cacheB = <String, AudioRegion?>{};
    AudioRegion? region(SectionIndex index, Map<String, AudioRegion?> cache, int start, int length) {
      final key = '$start:$length';
      if (!cache.containsKey(key)) cache[key] = index.at(start, length);
      return cache[key];
    }
    SectionProposal? best;
    for (final exit in exits) {
      for (final enter in entries) {
        final templates = <(String, int, double)>[
          ('shortFade', 2000, 1),
          if (allowCut) ('cut', 250, 1),
          ('atmospheric', 6000, 1),
          if (matched) for (final bars in [2, 4, 8])
            if (bars <= options.bars) ('beatBlend', (bars * 4 * 60000 / a.bpm!).round(), beat!.rate),
        ];
        for (final (kind, wanted, rate) in templates) {
          final len = math.min(wanted, math.min(a.endMs - exit, ((b.endMs - enter) / rate).floor()));
          if (len < 200 || (kind == 'beatBlend' && len < wanted)) continue;
          final incomingMs = (len * rate).ceil();
          // Statistics must describe the actual audible window. A cut uses a
          // short inspection window on either side, not just a single sample.
          final inspect = kind == 'cut' ? 1000 : len;
          final ra = region(sa, cacheA, math.max(a.introMs, exit - (kind == 'cut' ? 500 : 0)), inspect);
          final rb = region(sb, cacheB, enter, kind == 'cut' ? 1000 : incomingMs);
          if (ra == null || rb == null || ra.activeFraction < 0.35 || rb.activeFraction < 0.35) continue;
          final isBeat = kind == 'beatBlend';
          final boundaryA = math.max(sa.confidenceAt(exit), _phraseConfidence(fa.dj, exit));
          final boundaryB = math.max(sb.confidenceAt(enter), _phraseConfidence(fb.dj, enter));
          if (kind == 'cut' && (boundaryA < 0.4 || boundaryB < 0.25)) continue;
          if (isBeat && (!_onGrid(exit, a.tailBarMs ?? a.tailBeatMs, a.bpm) ||
              !_onGrid(enter, b.headBarMs ?? b.headBeatMs, b.bpm))) continue;
          final voiceA = ra.reliableVocals ? ra.vocalProbability : _proxy(fa.dj, exit, len);
          final voiceB = rb.reliableVocals ? rb.vocalProbability : _proxy(fb.dj, enter, incomingMs);
          final measured = ra.reliableVocals && rb.reliableVocals;
          final unknown = voiceA == null || voiceB == null;
          final vocalClash = voiceA != null && voiceB != null && voiceA > (measured ? 0.5 : 0.65) && voiceB > (measured ? 0.5 : 0.65);
          if (len > 2000 && (unknown || vocalClash)) continue;
          if (kind == 'atmospheric' && (ra.onsetDensity > 1 || rb.onsetDensity > 1 || ra.bassRatio > 0.5 || rb.bassRatio > 0.5)) continue;
          final energy = math.exp(-(ra.energyDb - rb.energyDb).abs() / 10);
          final spectral = math.exp(-(ra.centroidHz - rb.centroidHz).abs() / 2500);
          var timbreDistance = 0.0;
          for (var k = 0; k < 12; k++) { timbreDistance += math.pow(ra.mfcc[k] - rb.mfcc[k], 2); }
          final timbre = math.exp(-math.sqrt(timbreDistance / 12) / 16);
          final harmonic = _cosine(ra.chroma, rb.chroma);
          final rhythm = math.exp(-(ra.onsetDensity - rb.onsetDensity).abs() / 2);
          final bass = (1 - (ra.bassRatio - rb.bassRatio).abs()).clamp(0.0, 1.0).toDouble();
          final stretch = (rate - 1).abs() / math.max(0.01, options.range);
          final discardedTail = (a.endMs - exit - len).clamp(0, 60000);
          final peakA = ra.samplePeakDb, peakB = rb.samplePeakDb;
          // Conservative mono source peak bound, not a stereo true-peak meter.
          final peakBound = peakA == null || peakB == null ? null :
              20 * math.log(math.pow(10, peakA / 20) + math.pow(10, peakB / 20)) / math.ln10;
          final peakPenalty = kind == 'cut' ? 0.0 : peakBound == null ? 0.03 : math.max(0.0, peakBound + 1) / 30;
          final components = <String, double>{'energy': energy, 'spectral': spectral, 'timbre': timbre,
            'harmony': harmonic, 'rhythm': rhythm, 'bass': bass, 'boundary': (boundaryA + boundaryB) / 2,
            'stretchCost': stretch, 'vocalRisk': vocalClash ? 1 : unknown ? 0.5 : measured ? 0 : 0.2,
            'peakPenalty': peakPenalty, 'discardedTailMs': discardedTail.toDouble()};
          final score = 0.22 * energy + 0.12 * spectral + 0.16 * timbre + 0.1 * harmonic +
              0.1 * rhythm + 0.08 * bass + 0.14 * components['boundary']! +
              (isBeat ? 0.08 : kind == 'atmospheric' ? 0.04 : 0) - 0.06 * stretch - peakPenalty -
              (vocalClash ? 0.1 : unknown ? 0.06 : 0) - discardedTail / 300000 -
              (kind == 'cut' ? 0.045 : kind == 'shortFade' ? 0.02 : 0);
          if (best != null && score <= best.score) continue;
          Duration? swap;
          if (isBeat && options.bass && a.bpm != null) {
            final bar = 4 * 60000 / a.bpm!;
            final middleBar = ((len / 2) / bar).round();
            final at = (math.max(1, middleBar) * bar).round();
            if (at > 0 && at < len) swap = Duration(milliseconds: at);
          }
          final gain = math.pow(10, (ra.energyDb - rb.energyDb).clamp(-6.0, 6.0) / 20).toDouble();
          final p = MixPlan(Duration(milliseconds: exit), Duration(milliseconds: len), Duration(milliseconds: enter), gain,
              dj: isBeat, rate: rate, grid: isBeat ? beat!.grid : null, offsetMs: isBeat ? options.offsetMs : 0,
              swapAt: swap, preroll: isBeat ? Duration(milliseconds: math.min(700, (enter / rate).floor())) : Duration.zero);
          best = SectionProposal(p, kind, score.clamp(0.0, 1.0).toDouble(), components, [
            'Локальные участки: $exit → $enter мс; ${len / 1000} с',
            'Энергия/тембр/гармония/ритм оценены в выбранных окнах',
            measured ? 'Есть независимые данные о вокале' : unknown ? 'Вокал неизвестен: только короткое наложение' : 'Вокал: только эвристика, не подтверждённая вероятность',
            if (vocalClash) 'Наложение голосов запрещает длинный blend',
            if (peakBound != null) 'Консервативная оценка пика исходного mono: ${peakBound.toStringAsFixed(1)} dBFS',
          ]);
        }
      }
    }
    return best;
  }

  static List<int> _cues(SectionIndex sx, DjData? dj, int from, int to, int preferred, int limit) {
    if (to < from) return const [];
    final candidates = <int>{preferred.clamp(from, to).toInt(), ...sx.boundaries(fromMs: from, toMs: to)};
    if (dj != null && dj.phraseConf >= 0.2) candidates.addAll(dj.phrasesMs.where((p) => p >= from && p <= to));
    // Also expose bar-aligned candidates: a novelty window need not land on a beat.
    final bpm = dj?.gridBpm, anchor = dj?.barAnchorMs ?? dj?.firstBeatMs;
    if (dj?.gridStable == true && bpm != null && anchor != null && bpm.isFinite && bpm > 0) {
      final bar = 4 * 60000 / bpm;
      final k = ((preferred - anchor) / bar).floor();
      for (var d = -3; d <= 3; d++) {
        final p = (anchor + (k + d) * bar).round();
        if (p >= from && p <= to) candidates.add(p);
      }
    }
    final sorted = candidates.toList()..sort((a, b) {
      final qa = math.max(sx.confidenceAt(a), _phraseConfidence(dj, a)) - (a - preferred).abs() / 200000;
      final qb = math.max(sx.confidenceAt(b), _phraseConfidence(dj, b)) - (b - preferred).abs() / 200000;
      final score = qb.compareTo(qa);
      return score != 0 ? score : a.compareTo(b);
    });
    return sorted.take(limit).toList();
  }

  static double _phraseConfidence(DjData? d, int at) => d != null && d.phrasesMs.any((p) => (p - at).abs() <= 50) ? d.phraseConf : 0;
  static bool _onGrid(int at, int? anchor, double? bpm) {
    if (anchor == null || bpm == null || !bpm.isFinite || bpm <= 0) return false;
    final bar = 4 * 60000 / bpm;
    final phase = ((at - anchor) % bar).abs();
    return math.min(phase, bar - phase) <= 50;
  }
  static double _cosine(List<double> a, List<double> b) {
    var dot = 0.0, aa = 0.0, bb = 0.0;
    for (var i = 0; i < 12; i++) { dot += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i]; }
    return aa > 0 && bb > 0 ? (dot / math.sqrt(aa * bb)).clamp(0.0, 1.0).toDouble() : 0.5;
  }
  static double? _proxy(DjData? d, int start, int len) {
    final c = d?.vocalCurve, a = start ~/ 1000, b = ((start + len) / 1000).ceil();
    if (c == null || a < 0 || b > c.length || b <= a) return null;
    var sum = 0;
    for (var i = a; i < b; i++) { sum += c[i]; }
    return sum / (b - a) / 100;
  }
}
