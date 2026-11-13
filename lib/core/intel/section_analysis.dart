import 'dart:math' as math;
import 'dart:typed_data';
import 'features.dart';
import 'sections.dart';

/// Four-second windows throughout a full decode, independently of beat success.
/// No music-function labels or singing probabilities are invented here.
SectionIndex analyzeSections(FrameSet frames, Uint8List pcm22, {Float64List? onsets}) {
  const windowMs = 4000;
  final decodedMs = (pcm22.length / 2 / intelRate * 1000).floor();
  final data = ByteData.sublistView(pcm22);
  final out = <AudioRegion>[];
  for (var start = 0; start < decodedMs && out.length < SectionIndex.maxRegions; start += windowMs) {
    final end = math.min(decodedMs, start + windowMs);
    if (end - start < 500) break;
    final a = (start * intelFps / 1000).floor().clamp(0, frames.count).toInt();
    final b = (end * intelFps / 1000).ceil().clamp(a, frames.count).toInt();
    if (a == b) continue;
    var active = 0, energy = 0.0, centroid = 0.0, bass = 0.0;
    final mfcc = List.filled(12, 0.0), chroma = List.filled(12, 0.0);
    for (var i = a; i < b; i++) {
      energy += frames.rmsDb[i];
      if (!frames.active(i)) continue;
      active++; centroid += frames.centroid[i]; bass += frames.bass[i];
      for (var k = 0; k < 12; k++) { mfcc[k] += frames.mfcc[i * 12 + k]; chroma[k] += frames.chroma[i * 12 + k]; }
    }
    var peak = 0.0;
    final sampleEnd = math.min(pcm22.length ~/ 2, end * intelRate ~/ 1000);
    for (var i = start * intelRate ~/ 1000; i < sampleEnd; i++) {
      peak = math.max(peak, data.getInt16(i * 2, Endian.little).abs() / 32768);
    }
    final n = math.max(1, active);
    final current = AudioRegion(startMs: start, endMs: end,
        energyDb: energy / (b - a), centroidHz: centroid / n, bassRatio: bass / n,
        onsetDensity: onsets == null ? 0 : onsetsPerSecond(onsets, from: start ~/ 10, to: end ~/ 10),
        activeFraction: active / (b - a), mfcc: [for (final x in mfcc) x / n], chroma: [for (final x in chroma) x / n],
        samplePeakDb: peak <= 1e-9 ? -120 : 20 * math.log(peak) / math.ln10);
    var boundary = 0.0;
    if (out.isNotEmpty) {
      final prev = out.last;
      var timbre = 0.0;
      for (var k = 0; k < 12; k++) { timbre += math.pow(current.mfcc[k] - prev.mfcc[k], 2); }
      boundary = (0.45 * ((current.energyDb - prev.energyDb).abs() / 12).clamp(0.0, 1.0) +
          0.35 * (math.sqrt(timbre / 12) / 16).clamp(0.0, 1.0) +
          0.2 * ((current.bassRatio - prev.bassRatio).abs() / 0.4).clamp(0.0, 1.0)).toDouble();
    }
    out.add(current.withBoundary(boundary));
  }
  return SectionIndex(List.unmodifiable(out));
}
