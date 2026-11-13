import 'dart:math' as math;
import 'dart:typed_data';
import 'features.dart';
import 'sections.dart';

/// Four-second windows throughout a full decode, independently of beat success.
/// No music-function labels or singing probabilities are invented here.
SectionIndex analyzeSections(FrameSet frames, Uint8List pcm22,
    {Float64List? onsets}) {
  const windowMs = 4000;
  final decodedMs = (pcm22.length / 2 / intelRate * 1000).floor();
  final data = ByteData.sublistView(pcm22);
  final out = <AudioRegion>[];
  for (var start = 0;
      start < decodedMs && out.length < SectionIndex.maxRegions;
      start += windowMs) {
    final end = math.min(decodedMs, start + windowMs);
    if (end - start < 500) break;
    final a = (start * intelFps / 1000).floor().clamp(0, frames.count).toInt();
    final b = (end * intelFps / 1000).ceil().clamp(a, frames.count).toInt();
    if (a == b) continue;
    var active = 0, energy = 0.0, centroid = 0.0, bass = 0.0;
    var attackCount = 0, attackHz = 0.0, attackBass = 0.0;
    final mfcc = List.filled(12, 0.0), chroma = List.filled(12, 0.0);
    for (var i = a; i < b; i++) {
      energy += frames.rmsDb[i];
      if (!frames.active(i)) continue;
      active++;
      centroid += frames.centroid[i];
      bass += frames.bass[i];
      for (var k = 0; k < 12; k++) {
        mfcc[k] += frames.mfcc[i * 12 + k];
        chroma[k] += frames.chroma[i * 12 + k];
      }
    }
    var peak = 0.0;
    if (onsets != null) {
      for (var j = math.max(1, start ~/ 10);
          j < math.min(onsets.length - 1, end ~/ 10);
          j++) {
        if (onsets[j] < 3 ||
            onsets[j] <= onsets[j - 1] ||
            onsets[j] < onsets[j + 1]) continue;
        final f = (j * 10 * intelFps / 1000).round().clamp(a, b - 1).toInt();
        if (!frames.active(f)) continue;
        attackCount++;
        attackHz += frames.centroid[f];
        attackBass += frames.bass[f];
      }
    }
    final sampleEnd = math.min(pcm22.length ~/ 2, end * intelRate ~/ 1000);
    for (var i = start * intelRate ~/ 1000; i < sampleEnd; i++) {
      peak = math.max(peak, data.getInt16(i * 2, Endian.little).abs() / 32768);
    }
    final n = math.max(1, active);
    final current = AudioRegion(
        startMs: start,
        endMs: end,
        energyDb: energy / (b - a),
        centroidHz: centroid / n,
        bassRatio: bass / n,
        onsetDensity: onsets == null
            ? 0
            : onsetsPerSecond(onsets, from: start ~/ 10, to: end ~/ 10),
        activeFraction: active / (b - a),
        mfcc: [for (final x in mfcc) x / n],
        chroma: [for (final x in chroma) x / n],
        samplePeakDb: peak <= 1e-9 ? -120 : 20 * math.log(peak) / math.ln10,
        attackCentroidHz: attackCount > 0 ? attackHz / attackCount : null,
        attackBassRatio: attackCount > 0 ? attackBass / attackCount : null);
    var boundary = 0.0;
    if (out.isNotEmpty) {
      final prev = out.last;
      var timbre = 0.0;
      for (var k = 0; k < 12; k++) {
        timbre += math.pow(current.mfcc[k] - prev.mfcc[k], 2);
      }
      boundary = (0.45 *
                  ((current.energyDb - prev.energyDb).abs() / 12)
                      .clamp(0.0, 1.0) +
              0.35 * (math.sqrt(timbre / 12) / 16).clamp(0.0, 1.0) +
              0.2 *
                  ((current.bassRatio - prev.bassRatio).abs() / 0.4)
                      .clamp(0.0, 1.0))
          .toDouble();
    }
    out.add(current.withBoundary(boundary));
  }
  return analyzeRecurrence(SectionIndex(List.unmodifiable(out)));
}

double _similar(AudioRegion a, AudioRegion b) {
  var distance = 0.0, dot = 0.0, aa = 0.0, bb = 0.0;
  for (var k = 0; k < 12; k++) {
    distance += math.pow(a.mfcc[k] - b.mfcc[k], 2);
    dot += a.chroma[k] * b.chroma[k];
    aa += a.chroma[k] * a.chroma[k];
    bb += b.chroma[k] * b.chroma[k];
  }
  final harmonic = aa > 0 && bb > 0 ? dot / math.sqrt(aa * bb) : 0.5;
  return 0.55 * math.exp(-math.sqrt(distance / 12) / 12) +
      0.25 * harmonic +
      0.2 * math.exp(-(a.energyDb - b.energyDb).abs() / 10);
}

/// Two-sided novelty and nonadjacent recurrence. Cluster is not semantic function.
SectionIndex analyzeRecurrence(SectionIndex index) {
  final rows = index.regions,
      out = <AudioRegion>[],
      exemplars = <AudioRegion>[];
  final clusters = <int>[];
  for (var i = 0; i < rows.length; i++) {
    final current = rows[i];
    var novelty = current.boundaryConfidence;
    if (i >= 2 && i + 1 < rows.length) {
      final within = (_similar(rows[i - 2], rows[i - 1]) +
              _similar(rows[i], rows[i + 1])) /
          2;
      var across = 0.0;
      for (var a = i - 2; a < i; a++) {
        for (var b = i; b < i + 2; b++) {
          across += _similar(rows[a], rows[b]);
        }
      }
      novelty = math.max(novelty, ((within - across / 4) * 2).clamp(0.0, 1.0));
    }
    var best = -1, similarity = 0.0;
    for (var c = 0; c < exemplars.length; c++) {
      final fit = _similar(current, exemplars[c]);
      if (fit > similarity) {
        similarity = fit;
        best = c;
      }
    }
    if (best < 0 || similarity < 0.86) {
      best = exemplars.length;
      exemplars.add(current);
      similarity = 0;
    }
    final recurrent = [
      for (var j = 0; j < clusters.length; j++)
        if (clusters[j] == best && current.startMs - rows[j].endMs >= 16000) j
    ];
    clusters.add(best);
    out.add(current.copyWith(
        boundaryConfidence: novelty,
        recurrenceCluster: best,
        recurrenceConfidence: recurrent.isEmpty ? 0 : similarity));
  }
  return SectionIndex(List.unmodifiable(out));
}
