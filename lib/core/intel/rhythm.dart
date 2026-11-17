import 'dart:math' as math;
import 'dart:typed_data';
import '../beats.dart' show beatPhase, findTempo, refineTempo;

/// Local pulse hypothesis backed by observed source-time attacks. No meter or
/// downbeat is asserted; estimator support is not calibrated probability.
class RhythmWindow {
  final int startMs, endMs;
  final double bpm, confidence, support, residualMs;
  final List<int> beatsMs;
  final List<double> groove, lowGroove;
  RhythmWindow(
      {required this.startMs,
      required this.endMs,
      required this.bpm,
      required this.confidence,
      required this.support,
      required this.residualMs,
      required this.beatsMs,
      required this.groove,
      required this.lowGroove});
  // Both checks walk every beat and are asked for thousands of times by one
  // planning pass (windows x windows x cue pairs), so they are computed once.
  late final bool valid = _checkValid();
  late final bool reliable = valid &&
      confidence >= 0.1 &&
      support >= 0.72 &&
      residualMs <= 30 &&
      beatsMs.length >= 12;
  bool _checkValid() {
    if (startMs < 0 ||
        endMs <= startMs ||
        !bpm.isFinite ||
        bpm < 40 ||
        bpm > 250 ||
        !confidence.isFinite ||
        confidence < 0 ||
        confidence > 1 ||
        !support.isFinite ||
        support < 0 ||
        support > 1 ||
        !residualMs.isFinite ||
        residualMs < 0 ||
        beatsMs.length > 256) return false;
    for (var i = 0; i < beatsMs.length; i++) {
      final t = beatsMs[i];
      if (t < startMs || t >= endMs || (i > 0 && t <= beatsMs[i - 1])) {
        return false;
      }
    }
    for (final p in [groove, lowGroove]) {
      if (p.length != 8) return false;
      for (final x in p) {
        if (!x.isFinite || x < 0 || x > 1) return false;
      }
    }
    return true;
  }

  /// Beats are strictly ascending, so the nearest one is found by bisection.
  bool onBeat(int at) {
    var lo = 0, hi = beatsMs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (beatsMs[mid] < at - 25) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < beatsMs.length && beatsMs[lo] <= at + 25;
  }
  Map<String, Object> toJson() => {
        's': startMs,
        'e': endMs,
        'bpm': bpm,
        'conf': confidence,
        'support': support,
        'residual': residualMs,
        'beats': beatsMs,
        'groove': groove,
        'low': lowGroove
      };
  static RhythmWindow? fromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      final w = RhythmWindow(
          startMs: (raw['s'] as num).toInt(),
          endMs: (raw['e'] as num).toInt(),
          bpm: (raw['bpm'] as num).toDouble(),
          confidence: (raw['conf'] as num).toDouble(),
          support: (raw['support'] as num).toDouble(),
          residualMs: (raw['residual'] as num).toDouble(),
          // Compact typed storage: the index keeps every record in memory.
          beatsMs: Int32List.fromList(
              [for (final x in raw['beats'] as List) (x as num).toInt()]),
          groove: Float64List.fromList(
              [for (final x in raw['groove'] as List) (x as num).toDouble()]),
          lowGroove: Float64List.fromList(
              [for (final x in raw['low'] as List) (x as num).toDouble()]));
      return w.valid ? w : null;
    } catch (_) {
      return null;
    }
  }
}

class RhythmTimeline {
  static const version = 1, maxWindows = 256;
  final List<RhythmWindow> windows;
  const RhythmTimeline(this.windows);
  Map<String, Object> toJson() => {
        'v': version,
        'windows': [for (final w in windows) w.toJson()]
      };
  static RhythmTimeline? fromJson(Object? raw) {
    if (raw is! Map || raw['v'] != version || raw['windows'] is! List)
      return null;
    final rows = raw['windows'] as List;
    if (rows.length > maxWindows) return null;
    final out = <RhythmWindow>[];
    for (final row in rows) {
      final w = RhythmWindow.fromJson(row);
      if (w == null || (out.isNotEmpty && w.startMs <= out.last.startMs))
        return null;
      out.add(w);
    }
    return RhythmTimeline(List.unmodifiable(out));
  }

  RhythmWindow? at(int start, int length) {
    RhythmWindow? best;
    for (final w in windows) {
      if (w.startMs > start || w.endMs < start + length || !w.reliable)
        continue;
      if (best == null || w.residualMs < best.residualMs) best = w;
    }
    return best;
  }

  List<int> cues(int from, int to) => <int>{
        for (final w in windows)
          if (w.reliable)
            for (final b in w.beatsMs)
              if (b >= from && b <= to) b
      }.toList()
        ..sort();
}

/// 24 s windows / 8 s hop. Missing attacks are never filled in as fake beats.
RhythmTimeline analyzeRhythm(Float64List broad, Float64List low) {
  final n = math.min(broad.length, low.length);
  const size = 2400, step = 800;
  if (n < 1500) return const RhythmTimeline([]);
  final starts = <int>{
    for (var s = 0; s + size <= n; s += step) s,
    math.max(0, n - size)
  }.toList()
    ..sort();
  final windows = <RhythmWindow>[];
  for (final start in starts.take(RhythmTimeline.maxWindows)) {
    final end = math.min(n, start + size);
    final b = Float64List.sublistView(broad, start, end),
        l = Float64List.sublistView(low, start, end);
    final estimate = findTempo(b);
    if (estimate == null || estimate.$2 < 0.05) continue;
    final bpm = refineTempo(b, estimate.$1), period = 6000 / bpm;
    final phase = beatPhase(l.any((v) => v > 3) ? l : b, period, 0, b.length);
    if (phase < 0) continue;
    final attacks = <int>[
      for (var i = 1; i < b.length - 1; i++)
        if (b[i] >= 3 && b[i] > b[i - 1] && b[i] >= b[i + 1]) i
    ];
    final beats = <int>[];
    var squares = 0.0, expected = 0;
    for (var t = phase; t < b.length; t += period) {
      expected++;
      int? nearest;
      for (final a in attacks) {
        if ((a - t).abs() <= 7 &&
            (nearest == null || (a - t).abs() < (nearest - t).abs()))
          nearest = a;
      }
      if (nearest == null ||
          (beats.isNotEmpty && (start + nearest) * 10 <= beats.last)) continue;
      beats.add((start + nearest) * 10);
      squares += math.pow((nearest - t) * 10, 2);
    }
    List<double> pattern(Float64List o) {
      final bins = List.filled(8, 0.0);
      for (var i = 0; i < o.length; i++) {
        final bin = ((((i - phase) / period) % 1) * 8).round() % 8;
        bins[bin] += math.max(0, o[i]);
      }
      final norm = math.sqrt(bins.fold<double>(0, (s, v) => s + v * v));
      return [
        for (final v in bins)
          norm > 0 ? double.parse((v / norm).toStringAsFixed(4)) : 0.0
      ];
    }

    windows.add(RhythmWindow(
        startMs: start * 10,
        endMs: end * 10,
        bpm: bpm,
        confidence: estimate.$2,
        support: expected > 0 ? beats.length / expected : 0,
        residualMs: beats.isEmpty ? 999 : math.sqrt(squares / beats.length),
        beatsMs: List.unmodifiable(beats),
        groove: pattern(b),
        lowGroove: pattern(l)));
  }
  return RhythmTimeline(List.unmodifiable(windows));
}

double grooveSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0.5;
  var dot = 0.0, aa = 0.0, bb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    aa += a[i] * a[i];
    bb += b[i] * b[i];
  }
  return aa > 0 && bb > 0
      ? (dot / math.sqrt(aa * bb)).clamp(0.0, 1.0).toDouble()
      : 0.5;
}
