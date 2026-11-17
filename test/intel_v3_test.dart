import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/intel/rhythm.dart';
import 'package:cave_player/core/intel/vocal_activity.dart';
import 'package:cave_player/core/intel/adaptive_dj.dart';
import 'package:cave_player/core/intel/record.dart';
import 'package:cave_player/core/intel/sections.dart';
import 'package:cave_player/core/intel/section_analysis.dart';
import 'section_plan_test.dart' show sectional;

Float64List clicks(int seconds, double bpm, {int missingEvery = 0}) {
  final o = Float64List(seconds * 100);
  var k = 0;
  for (var t = 0.0; t < o.length; t += 6000 / bpm, k++) {
    if (missingEvery == 0 || k % missingEvery != 0) o[t.round()] = 12;
  }
  return o;
}

RhythmTimeline timeline(
        {List<double> pattern = const [1, 0, 0, 0, 0, 0, 0, 0]}) =>
    RhythmTimeline([
      for (final start in [0, 198000])
        RhythmWindow(
            startMs: start,
            endMs: start + 42000,
            bpm: 120,
            confidence: 0.9,
            support: 1,
            residualMs: 5,
            beatsMs: [for (var t = start; t < start + 42000; t += 500) t],
            groove: pattern,
            lowGroove: pattern)
    ]);
AdaptiveTrack rhythmic(String id,
    {List<double> pattern = const [1, 0, 0, 0, 0, 0, 0, 0]}) {
  final s = sectional(id, stable: false, measured: true);
  return AdaptiveTrack(
      id,
      s.profile,
      TrackFeatures.fromJson({
        ...s.features!.toJson(),
        'rt': timeline(pattern: pattern).toJson()
      }));
}

Map<String, Object> voiceJson({double score = 0.9}) => {
      'v': 1,
      'source': 'model:yamnet/float32/1',
      'modelSha256': VocalActivity.modelHash,
      'hopMs': 480,
      'windowMs': 975,
      'durationMs': 240000,
      'scores': List.filled(500, score)
    };
AudioRegion row(int i, bool b) => AudioRegion(
    startMs: i * 4000,
    endMs: (i + 1) * 4000,
    energyDb: b ? -10 : -24,
    centroidHz: b ? 6000 : 1500,
    bassRatio: b ? 0.1 : 0.6,
    onsetDensity: 2,
    activeFraction: 1,
    mfcc: List.filled(12, b ? 40 : 0),
    chroma: [for (var k = 0; k < 12; k++) k == (b ? 3 : 0) ? 1 : 0]);

void main() {
  test(
      'local tempo follows two stable sections rather than imposing global BPM',
      () {
    final o = Float64List.fromList([...clicks(32, 120), ...clicks(32, 150)]),
        r = analyzeRhythm(o, o);
    expect(r.windows.any((w) => w.reliable && (w.bpm - 120).abs() < 1), isTrue);
    expect(r.windows.any((w) => w.reliable && (w.bpm - 150).abs() < 1), isTrue);
  });
  test('observed timeline does not fill missing attacks with invented beats',
      () {
    final o = clicks(32, 120, missingEvery: 3), r = analyzeRhythm(o, o);
    for (final w in r.windows) {
      expect(w.beatsMs.every((t) => o[t ~/ 10] > 0), isTrue);
    }
    expect(r.at(0, 60000), isNull);
  });
  test('whole overlap coverage and ordered roundtrip are required', () {
    final t = timeline();
    expect(RhythmTimeline.fromJson(t.toJson())!.at(200000, 16000), isNotNull);
    expect(t.at(235000, 8000), isNull);
    final raw = t.toJson();
    (raw['windows'] as List).add((raw['windows'] as List).first);
    expect(RhythmTimeline.fromJson(raw), isNull);
  });
  test('local stable pulses permit blend despite unstable global grid', () {
    final d = AdaptiveDj.pair(rhythmic('a'), rhythmic('b'));
    expect(d.plan!.dj, isTrue);
    expect(d.components['localRhythmResidualMs'], 5);
    expect(d.plan!.grid!.$1, d.plan!.start.inMilliseconds);
    expect(d.plan!.start + d.plan!.length,
        lessThanOrEqualTo(const Duration(milliseconds: 238000)));
  });
  test('different grooves limit the technique without excluding the track', () {
    final d = AdaptiveDj.pair(
        rhythmic('a'), rhythmic('b', pattern: const [0, 0, 0, 0, 1, 0, 0, 0]));
    expect(d.to, 'b');
    expect(d.plan!.length.inMilliseconds, lessThanOrEqualTo(8000));
    expect(d.technique, isNot(AdaptiveTechnique.cut));
    expect(grooveSimilarity([1, 0], [0, 1]), 0);
  });
  test('novelty detects change and recurrence finds a nonadjacent return', () {
    final sx = analyzeRecurrence(
        SectionIndex([for (var i = 0; i < 12; i++) row(i, i >= 4 && i < 8)]));
    expect(sx.regions[4].boundaryConfidence, greaterThan(0.4));
    expect(sx.regions[8].recurrenceCluster, sx.regions.first.recurrenceCluster);
    expect(sx.regions[8].recurrenceConfidence, greaterThan(0.85));
    expect(sx.regions[1].recurrenceConfidence, 0);
    expect(sx.regions[8].toJson()['function'], 'unknown');
  });
  test('optional descriptors preserve old records and validate new ones', () {
    final r =
        row(0, false).copyWith(recurrenceCluster: 2, recurrenceConfidence: 0.9);
    expect(AudioRegion.fromJson(r.toJson())!.recurrenceCluster, 2);
    final raw = r.toJson()
      ..remove('cluster')
      ..remove('recurrence')
      ..remove('function');
    expect(AudioRegion.fromJson(raw), isNotNull);
    expect(AudioRegion.fromJson({...raw, 'attackBass': 2}), isNull);
  });
  test('voice identity and coverage cannot be forged by malformed extension',
      () {
    expect(VocalActivity.fromJson(voiceJson()), isNotNull);
    for (final change in [
      {'modelSha256': 'other'},
      {
        'scores': [0.1]
      },
      {'hopMs': 0},
      {'scores': List.filled(500, double.nan)}
    ]) {
      expect(VocalActivity.fromJson({...voiceJson(), ...change}), isNull);
    }
  });
  test('risk uses actual interval and low score remains uncertain', () {
    final raw = voiceJson(score: 0.02);
    (raw['scores'] as List)[10] = 0.95;
    final v = VocalActivity.fromJson(raw)!;
    expect(v.riskAt(5000, 3000), 0.95);
    expect(v.riskAt(20000, 3000), 0.02);
    expect(v.riskAt(239000, 2000), isNull);
    expect(v.toJson()['calibratedAbsence'], isFalse);
  });
  test('concurrent learned voice risk prohibits a long blend despite low proxy',
      () {
    AdaptiveTrack t(String id) {
      final s = sectional(id);
      return AdaptiveTrack(id, s.profile,
          TrackFeatures.fromJson({...s.features!.toJson(), 'va': voiceJson()}));
    }

    final d = AdaptiveDj.pair(t('a'), t('b'));
    expect(d.plan!.length.inMilliseconds, lessThanOrEqualTo(2000));
    expect(d.components['vocalRisk'], 1);
    expect(d.components['voiceModelIn'], 0.9);
  });
  test(
      'voices at different times do not collide; source cue conversion can align them',
      () {
    final ra = voiceJson(score: 0.01), rb = voiceJson(score: 0.01);
    for (var i = 4; i < 10; i++) {
      (ra['scores'] as List)[i] = 0.9;
    }
    for (var i = 20; i < 26; i++) {
      (rb['scores'] as List)[i] = 0.9;
    }
    final a = VocalActivity.fromJson(ra)!, b = VocalActivity.fromJson(rb)!;
    expect(VocalActivity.collision(a, b, 0, 0, 14000, 1)!.concurrentMs, 0);
    expect(VocalActivity.collision(a, b, 0, 7680, 6000, 1)!.risky, isTrue);
    expect(VocalActivity.collision(a, b, 239000, 0, 6000, 1), isNull);
  });
}
