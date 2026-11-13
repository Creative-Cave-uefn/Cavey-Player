import 'sections.dart';

/// Optional evidence from a reviewed annotation or a separately supplied model.
/// The source string is provenance, not a certification of model accuracy.
class VocalObservation {
  final int startMs, endMs;
  final double probability, confidence;
  const VocalObservation(this.startMs, this.endMs, this.probability, this.confidence);
  static VocalObservation parse(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid vocal interval');
    final v = VocalObservation((raw['startMs'] as num).toInt(), (raw['endMs'] as num).toInt(),
        (raw['probability'] as num).toDouble(), (raw['confidence'] as num).toDouble());
    if (v.startMs < 0 || v.endMs <= v.startMs || !v.probability.isFinite ||
        v.probability < 0 || v.probability > 1 || !v.confidence.isFinite || v.confidence < 0 || v.confidence > 1) {
      throw const FormatException('Invalid vocal interval bounds/probability');
    }
    return v;
  }
}

SectionIndex applyVocalAnnotations(SectionIndex index, List<VocalObservation> evidence, String source) {
  if (!(source == 'annotation' || source.startsWith('model:')) || source.length > 128 || evidence.length > 10000) {
    throw const FormatException('Specify annotation or model:<checkpoint> source');
  }
  var previousEnd = -1;
  for (final v in evidence) {
    if (v.startMs < previousEnd || v.endMs <= v.startMs || v.startMs < 0 ||
        !v.probability.isFinite || !v.confidence.isFinite || v.probability < 0 || v.probability > 1 ||
        v.confidence < 0 || v.confidence > 1) throw const FormatException('Overlapping or invalid vocal intervals');
    previousEnd = v.endMs;
  }
  final out = <AudioRegion>[];
  for (final r in index.regions) {
    var covered = 0, probability = 0.0, confidence = 0.0;
    for (final v in evidence) {
      final a = v.startMs > r.startMs ? v.startMs : r.startMs;
      final b = v.endMs < r.endMs ? v.endMs : r.endMs;
      if (b <= a) continue;
      final weight = b - a;
      covered += weight; probability += v.probability * weight; confidence += v.confidence * weight;
    }
    if (covered < (r.endMs - r.startMs) * 0.9) { out.add(r); continue; }
    out.add(AudioRegion(startMs: r.startMs, endMs: r.endMs, energyDb: r.energyDb, centroidHz: r.centroidHz,
        bassRatio: r.bassRatio, onsetDensity: r.onsetDensity, activeFraction: r.activeFraction,
        mfcc: r.mfcc, chroma: r.chroma, boundaryConfidence: r.boundaryConfidence, samplePeakDb: r.samplePeakDb,
        vocalProbability: probability / covered, vocalConfidence: confidence / covered, vocalSource: source));
  }
  return SectionIndex(List.unmodifiable(out));
}
