/// Broad audio-event scores: high is positive voice risk, low is NOT calibrated
/// evidence of instrumental music. Temporal resolution is 480/975 ms, not 10 Hz.
class VocalActivity {
  static const version = 1;
  static const modelHash =
      '4d8b4a53282dc83ef04e3e7dbc4fbc98082e34e44ed798e16c3a0cdd4c584faf';
  final int hopMs, windowMs, durationMs;
  final List<double> scores;
  final String source, modelSha256;
  const VocalActivity(
      {required this.hopMs,
      required this.windowMs,
      required this.durationMs,
      required this.scores,
      required this.source,
      required this.modelSha256});
  static VocalActivity? fromJson(Object? raw) {
    if (raw is! Map || raw['v'] != version) return null;
    try {
      final a = VocalActivity(
          hopMs: (raw['hopMs'] as num).toInt(),
          windowMs: (raw['windowMs'] as num).toInt(),
          durationMs: (raw['durationMs'] as num).toInt(),
          source: raw['source'] as String,
          modelSha256: raw['modelSha256'] as String,
          scores: [
            for (final s in raw['scores'] as List) (s as num).toDouble()
          ]);
      if (a.hopMs != 480 ||
          a.windowMs != 975 ||
          a.durationMs <= 0 ||
          a.durationMs > 900000 ||
          a.source != 'model:yamnet/float32/1' ||
          a.modelSha256 != modelHash ||
          a.scores.isEmpty ||
          a.scores.length > 1876 ||
          (a.scores.length - 1) * a.hopMs >= a.durationMs ||
          (a.scores.length - 1) * a.hopMs + a.windowMs <
              a.durationMs - a.hopMs ||
          a.scores.any((s) => !s.isFinite || s < 0 || s > 1)) return null;
      return a;
    } catch (_) {
      return null;
    }
  }

  Map<String, Object> toJson() => {
        'v': version,
        'source': source,
        'modelSha256': modelSha256,
        'hopMs': hopMs,
        'windowMs': windowMs,
        'durationMs': durationMs,
        'calibratedAbsence': false,
        'scores': [for (final s in scores) double.parse(s.toStringAsFixed(4))]
      };
  double? riskAt(int start, int length) {
    if (start < 0 ||
        length <= 0 ||
        start + length > durationMs ||
        start + length > (scores.length - 1) * hopMs + windowMs) return null;
    double? risk;
    final first = (((start - windowMs) / hopMs).floor() + 1)
        .clamp(0, scores.length - 1)
        .toInt();
    final last =
        ((start + length - 1) ~/ hopMs).clamp(0, scores.length - 1).toInt();
    for (var i = first; i <= last; i++) {
      if (risk == null || scores[i] > risk) risk = scores[i];
    }
    return risk;
  }

  static VocalCollision? collision(VocalActivity a, VocalActivity b, int outMs,
      int inMs, int lengthMs, double rate) {
    if (lengthMs <= 0 || !rate.isFinite || rate <= 0) return null;
    var concurrent = 0, run = 0, longest = 0;
    for (var t = 0; t < lengthMs; t += 240) {
      final step = lengthMs - t < 240 ? lengthMs - t : 240;
      final va = a.riskAt(outMs + t, step),
          vb = b.riskAt(inMs + (t * rate).floor(), (step * rate).ceil());
      if (va == null || vb == null) return null;
      if (va >= 0.55 && vb >= 0.55) {
        concurrent += step;
        run += step;
        if (run > longest) longest = run;
      } else {
        run = 0;
      }
    }
    return VocalCollision(concurrent, longest, concurrent / lengthMs);
  }
}

class VocalCollision {
  final int concurrentMs, longestRunMs;
  final double fraction;
  const VocalCollision(this.concurrentMs, this.longestRunMs, this.fraction);
  bool get risky => longestRunMs >= 1440 || fraction >= 0.35;
}
