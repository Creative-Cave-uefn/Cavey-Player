import 'dart:math' as math;

/// Source-time descriptors. Unknown vocals stay null: a midrange proxy is not
/// a measured singing probability. Older index readers ignore this extension.
class AudioRegion {
  final int startMs, endMs;
  final double energyDb, centroidHz, bassRatio, onsetDensity, activeFraction;
  final List<double> mfcc, chroma;
  final double boundaryConfidence;
  final double? vocalProbability, vocalConfidence, samplePeakDb;
  final String vocalSource;
  const AudioRegion({required this.startMs, required this.endMs,
    required this.energyDb, required this.centroidHz, required this.bassRatio,
    required this.onsetDensity, required this.activeFraction,
    required this.mfcc, required this.chroma, this.boundaryConfidence = 0,
    this.vocalProbability, this.vocalConfidence, this.vocalSource = 'unknown', this.samplePeakDb});

  bool get valid => startMs >= 0 && endMs > startMs && energyDb.isFinite &&
      centroidHz.isFinite && centroidHz >= 0 && bassRatio.isFinite && bassRatio >= 0 && bassRatio <= 1 &&
      onsetDensity.isFinite && onsetDensity >= 0 && activeFraction.isFinite && activeFraction >= 0 && activeFraction <= 1 &&
      boundaryConfidence.isFinite && boundaryConfidence >= 0 && boundaryConfidence <= 1 &&
      mfcc.length == 12 && chroma.length == 12 && mfcc.every((x) => x.isFinite) &&
      chroma.every((x) => x.isFinite && x >= 0) &&
      (samplePeakDb == null || samplePeakDb!.isFinite) &&
      (vocalProbability == null || (vocalProbability!.isFinite && vocalProbability! >= 0 && vocalProbability! <= 1)) &&
      (vocalConfidence == null || (vocalConfidence!.isFinite && vocalConfidence! >= 0 && vocalConfidence! <= 1));

  bool get reliableVocals => vocalSource != 'unknown' && vocalSource != 'heuristic' &&
      vocalProbability != null && (vocalConfidence ?? 0) >= 0.75;

  AudioRegion withBoundary(double confidence) => AudioRegion(startMs: startMs, endMs: endMs,
      energyDb: energyDb, centroidHz: centroidHz, bassRatio: bassRatio, onsetDensity: onsetDensity,
      activeFraction: activeFraction, mfcc: mfcc, chroma: chroma, boundaryConfidence: confidence,
      vocalProbability: vocalProbability, vocalConfidence: vocalConfidence, vocalSource: vocalSource, samplePeakDb: samplePeakDb);

  static double _round(double x, int digits) {
    final scale = math.pow(10, digits);
    return (x * scale).round() / scale;
  }
  Map<String, Object?> toJson() => {'s': startMs, 'e': endMs, 'db': _round(energyDb, 1), 'hz': centroidHz.round(),
    'bass': _round(bassRatio, 3), 'onsets': _round(onsetDensity, 2), 'active': _round(activeFraction, 3),
    'mfcc': [for (final x in mfcc) _round(x, 2)], 'chroma': [for (final x in chroma) _round(x, 4)],
    'boundary': _round(boundaryConfidence, 3), if (samplePeakDb != null) 'peak': _round(samplePeakDb!, 2),
    if (vocalProbability != null) 'vocal': _round(vocalProbability!, 3),
    if (vocalConfidence != null) 'vocalConf': _round(vocalConfidence!, 3), 'vocalSource': vocalSource};

  static AudioRegion? fromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      final r = AudioRegion(startMs: (raw['s'] as num).toInt(), endMs: (raw['e'] as num).toInt(),
          energyDb: (raw['db'] as num).toDouble(), centroidHz: (raw['hz'] as num).toDouble(),
          bassRatio: (raw['bass'] as num).toDouble(), onsetDensity: (raw['onsets'] as num).toDouble(),
          activeFraction: (raw['active'] as num).toDouble(), boundaryConfidence: (raw['boundary'] as num? ?? 0).toDouble(),
          mfcc: [for (final x in raw['mfcc'] as List) (x as num).toDouble()],
          chroma: [for (final x in raw['chroma'] as List) (x as num).toDouble()],
          samplePeakDb: (raw['peak'] as num?)?.toDouble(),
          vocalProbability: (raw['vocal'] as num?)?.toDouble(), vocalConfidence: (raw['vocalConf'] as num?)?.toDouble(),
          vocalSource: raw['vocalSource'] as String? ?? 'unknown');
      return r.valid ? r : null;
    } catch (_) { return null; }
  }
}

/// Bounded, nonoverlapping windows make weighted region statistics well-defined.
class SectionIndex {
  static const version = 1;
  static const maxRegions = 2048;
  final List<AudioRegion> regions;
  const SectionIndex(this.regions);

  static SectionIndex? fromJson(Object? raw) {
    if (raw is! Map || raw['v'] != version || raw['regions'] is! List) return null;
    final rows = raw['regions'] as List;
    if (rows.isEmpty || rows.length > maxRegions) return null;
    final out = <AudioRegion>[];
    for (final row in rows) {
      final r = AudioRegion.fromJson(row);
      if (r == null || (out.isNotEmpty && r.startMs < out.last.endMs)) return null;
      out.add(r);
    }
    return SectionIndex(List.unmodifiable(out));
  }
  Map<String, Object> toJson() => {'v': version, 'regions': [for (final r in regions) r.toJson()]};

  /// Return null rather than extrapolating across unavailable source audio.
  AudioRegion? at(int startMs, int lengthMs) {
    if (startMs < 0 || lengthMs <= 0) return null;
    final endMs = startMs + lengthMs;
    var covered = 0, db = 0.0, hz = 0.0, bass = 0.0, onset = 0.0, active = 0.0;
    var vocal = 0.0, vocalConf = 0.0, vocalMs = 0;
    double? peak;
    final mfcc = List.filled(12, 0.0), chroma = List.filled(12, 0.0);
    final sources = <String>{};
    for (final r in regions) {
      final weight = math.min(r.endMs, endMs) - math.max(r.startMs, startMs);
      if (weight <= 0) continue;
      covered += weight; db += r.energyDb * weight; hz += r.centroidHz * weight;
      bass += r.bassRatio * weight; onset += r.onsetDensity * weight; active += r.activeFraction * weight;
      for (var k = 0; k < 12; k++) { mfcc[k] += r.mfcc[k] * weight; chroma[k] += r.chroma[k] * weight; }
      if (r.samplePeakDb != null) peak = peak == null ? r.samplePeakDb : math.max(peak, r.samplePeakDb!);
      if (r.reliableVocals) {
        vocalMs += weight; vocal += r.vocalProbability! * weight; vocalConf += r.vocalConfidence! * weight;
        sources.add(r.vocalSource);
      }
    }
    if (covered < lengthMs * 0.9 || covered == 0) return null;
    final knownVoice = vocalMs >= lengthMs * 0.9;
    return AudioRegion(startMs: startMs, endMs: endMs, energyDb: db / covered, centroidHz: hz / covered,
        bassRatio: bass / covered, onsetDensity: onset / covered, activeFraction: active / covered,
        mfcc: [for (final x in mfcc) x / covered], chroma: [for (final x in chroma) x / covered],
        samplePeakDb: peak, vocalProbability: knownVoice ? vocal / vocalMs : null,
        vocalConfidence: knownVoice ? vocalConf / vocalMs : null,
        vocalSource: knownVoice ? (sources.length == 1 ? sources.first : 'mixed') : 'unknown');
  }

  /// Confidence denotes a descriptor discontinuity, never a semantic chorus/drop label.
  List<int> boundaries({required int fromMs, required int toMs, double confidence = 0.35}) => [
    for (final r in regions)
      if (r.startMs >= fromMs && r.startMs <= toMs && r.boundaryConfidence >= confidence) r.startMs,
  ];

  double confidenceAt(int atMs) {
    var best = 0.0;
    for (final r in regions) {
      if ((r.startMs - atMs).abs() <= 1000) best = math.max(best, r.boundaryConfidence);
    }
    return best;
  }
}
