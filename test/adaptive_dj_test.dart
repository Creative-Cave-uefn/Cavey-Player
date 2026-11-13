import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/automix.dart';
import 'package:cave_player/core/intel/adaptive_dj.dart';
import 'package:cave_player/core/intel/record.dart';
import 'intel_test.dart' show fakeRecord;

AdaptiveTrack song(String id, {double bpm = 120, String key = '8A', int vocal = 10,
    bool stable = true, double phraseConf = 0.8, String mode = 'full', bool curves = true,
    double energy = -22, double centroid = 1500, double coverage = 240}) {
  final p = MixProfile(durationMs: 240000, introMs: 1000, outroMs: 220000, endMs: 238000,
      loudDb: energy, bpm: bpm, key: key, headBeatMs: 0, tailBeatMs: 0, headBarMs: 0, tailBarMs: 0);
  final segment = SegmentStats(energyDb: energy, centroidHz: centroid, bassRatio: 0.3,
      onsetDensity: 2, mfcc: List.filled(12, 0.0), silenceMs: 1000);
  final dj = DjData(gridBpm: bpm, firstBeatMs: 0, headBeatMs: 0, tailBeatMs: 0,
      headBarMs: 0, tailBarMs: 0, barAnchorMs: 0, gridStable: stable,
      phraseConf: phraseConf, phrasesMs: [for (var i = 0; i <= 240000; i += 16000) i],
      energyCurve: curves ? Uint8List.fromList(List.filled(240, (energy + 100).round())) : Uint8List(0),
      vocalCurve: curves ? Uint8List.fromList(List.filled(240, vocal)) : Uint8List(0));
  final f = TrackFeatures.fromJson({...fakeRecord(id, 0, 0).toJson(),
    'dur': 240, 'cov': coverage, 'md': mode, 'bpm': bpm, 'bs': stable ? 0.9 : 0.2,
    'in': segment.toJson(), 'out': segment.toJson(), 'dj': dj.toJson()})!;
  return AdaptiveTrack(id, p, f);
}

void main() {
  test('stable analysed pair uses a beat blend', () {
    final d = AdaptiveDj.pair(song('a'), song('b'));
    expect(d.technique, AdaptiveTechnique.beatBlend);
    expect(d.plan!.dj, isTrue);
    expect(d.plan!.start + d.plan!.length, lessThanOrEqualTo(const Duration(milliseconds: 238000)));
  });
  test('full intelligence grid works without a second analyzer grid', () {
    final original = song('a');
    final envelopeOnly = MixProfile(durationMs: 240000, introMs: 1000,
        outroMs: 220000, endMs: 238000, loudDb: -22);
    final d = AdaptiveDj.pair(AdaptiveTrack('a', envelopeOnly, original.features), song('b'));
    expect(d.technique, AdaptiveTechnique.beatBlend);
    expect(d.plan!.grid, isNotNull);
  });
  test('disagreeing legacy grid does not override the complete intelligence grid', () {
    final original = song('a');
    final legacy = MixProfile(durationMs: 240000, introMs: 1000, outroMs: 220000,
        endMs: 238000, loudDb: -22, bpm: 92, headBeatMs: 180, tailBeatMs: 180);
    final d = AdaptiveDj.pair(AdaptiveTrack('a', legacy, original.features), song('b'));
    expect(d.technique, AdaptiveTechnique.beatBlend);
    expect(d.plan!.rate, closeTo(1, 0.001));
  });
  test('distant BPM and key remain eligible through a short fade', () {
    final d = AdaptiveDj.pair(song('a'), song('b', bpm: 92, key: '2B'), allowCut: false);
    expect(d.technique, AdaptiveTechnique.shortFade);
    expect(d.plan!.rate, 1);
    expect(d.plan!.length.inMilliseconds, lessThanOrEqualTo(2500));
    expect(d.score, greaterThan(0));
  });
  test('contrast can use a structural cut without vocal overlap', () {
    final d = AdaptiveDj.pair(song('a'), song('b', bpm: 92));
    expect(d.technique, AdaptiveTechnique.cut);
    expect(d.plan!.rate, 1);
  });
  test('unstable live rhythm never enables beatmatching', () {
    final d = AdaptiveDj.pair(song('a', stable: false), song('b'));
    expect(d.plan!.dj, isFalse);
    expect(d.plan!.rate, 1);
  });
  test('strong vocal proxy prohibits long overlap and supports a phrase cut', () {
    final d = AdaptiveDj.pair(song('a', vocal: 90), song('b', vocal: 90));
    expect(d.technique, AdaptiveTechnique.cut);
    expect(d.plan!.length.inMilliseconds, 250);
    final noCut = AdaptiveDj.pair(song('a', vocal: 90), song('b', vocal: 90), allowCut: false);
    expect(noCut.technique, AdaptiveTechnique.shortFade);
    expect(noCut.plan!.length.inMilliseconds, lessThanOrEqualTo(2000));
  });
  test('unknown vocal curves never imply a safe long overlay', () {
    final d = AdaptiveDj.pair(song('a', curves: false), song('b'));
    expect(d.plan!.dj, isFalse);
    expect(d.plan!.length.inMilliseconds, lessThanOrEqualTo(2000));
  });
  test('fast, partial and missing analysis use AutoMix without reordering', () {
    for (final a in [song('a', mode: 'fast'), song('a', coverage: 40),
      AdaptiveTrack('a', song('a').profile, null)]) {
      final d = AdaptiveDj.choose(a, [song('first'), song('second')]);
      expect(d.to, 'first');
      expect(d.technique, AdaptiveTechnique.autoMix);
      expect(d.plan!.dj, isFalse);
    }
  });
  test('outdated schema and decode gaps cannot enable adaptive mixing', () {
    final original = song('a');
    for (final overrides in <Map<String, dynamic>>[
      {'sv': 0}, {'q': [TrackFeatures.flagDecodeGap]},
    ]) {
      final stale = TrackFeatures.fromJson({...original.features!.toJson(), ...overrides})!;
      final d = AdaptiveDj.choose(AdaptiveTrack('a', original.profile, stale), [song('b')]);
      expect(d.technique, AdaptiveTechnique.autoMix);
    }
  });
  test('missing profiles preserve next track and ordinary player fallback', () {
    final d = AdaptiveDj.choose(const AdaptiveTrack('a', null, null), [song('b')]);
    expect(d.to, 'b');
    expect(d.plan, isNull);
  });
  test('beam search returns a deterministic three-step route without duplicates', () {
    final pool = [song('b'), song('c', bpm: 92), song('d', stable: false), song('e')];
    final d = AdaptiveDj.choose(song('a'), pool);
    expect(d.path.length, 3);
    expect(d.path.toSet().length, 3);
    expect(d.path, isNot(contains('a')));
    expect(d.path, AdaptiveDj.choose(song('a'), pool).path);
    expect(d.to, d.path.first);
  });
  test('candidate window is bounded, input order and contents are preserved', () {
    final pool = [for (var i = 0; i < 8; i++) song('b$i')];
    final before = pool.map((s) => s.id).toList();
    final d = AdaptiveDj.choose(song('a'), pool);
    expect(d.path.every((id) => before.take(5).contains(id)), isTrue);
    expect(pool.map((s) => s.id), before);
  });
  test('explicit earliest cue prohibits planning into the past', () {
    final d = AdaptiveDj.pair(song('a'), song('b'), earliestMs: 225000);
    expect(d.plan!.start.inMilliseconds, greaterThanOrEqualTo(225000));
  });
  test('section compatibility can beat a deceptive tempo match', () {
    final d = AdaptiveDj.choose(song('a'), [song('deceptive', energy: -45, centroid: 9000), song('contrast', bpm: 92)]);
    expect(d.to, 'contrast');
  });
  test('trace records exact repeatable cue points and technique', () {
    final d = AdaptiveDj.choose(song('a'), [song('b')]);
    expect(d.toJson()['outMs'], d.plan!.start.inMilliseconds);
    expect(d.toJson()['technique'], d.technique.name);
    expect(d.reasons, isNotEmpty);
    expect(d.alternatives.single['to'], 'b');
  });
}
