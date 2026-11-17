import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/intel/features.dart';
import 'package:cave_player/core/intel/record.dart';
import 'package:cave_player/core/intel/sections.dart';
import 'package:cave_player/core/intel/section_analysis.dart';
import 'intel_test.dart' show fakeRecord;

AudioRegion region(int start, {double energy = -20, double bass = 0.3, double? voice, String source = 'unknown'}) =>
    AudioRegion(startMs: start, endMs: start + 4000, energyDb: energy, centroidHz: 1500,
        bassRatio: bass, onsetDensity: 2, activeFraction: 1, mfcc: List.filled(12, 1.0),
        chroma: List.filled(12, 1 / 12), vocalProbability: voice, vocalConfidence: voice == null ? null : 0.9,
        vocalSource: source);

void main() {
  test('weighted interval uses actual local regions, not the track average', () {
    final sx = SectionIndex([region(0, energy: -12), region(4000, energy: -36)]);
    expect(sx.at(0, 2000)!.energyDb, -12);
    expect(sx.at(4000, 2000)!.energyDb, -36);
    expect(sx.at(2000, 4000)!.energyDb, -24);
  });
  test('missing coverage is unknown, never an extrapolated region', () {
    final sx = SectionIndex([region(0), region(8000)]);
    expect(sx.at(2000, 8000), isNull);
    expect(sx.at(-1, 1000), isNull);
    expect(sx.at(0, 0), isNull);
    expect(sx.at(20000, 1000), isNull);
  });
  test('section index roundtrips and rejects overlapping windows', () {
    final sx = SectionIndex([region(0), region(4000)]);
    expect(SectionIndex.fromJson(sx.toJson())!.at(0, 8000)!.energyDb, -20);
    expect(SectionIndex.fromJson(SectionIndex([region(0), region(2000)]).toJson()), isNull);
    expect(SectionIndex.fromJson({'v': 999, 'regions': []}), isNull);
  });
  test('malformed descriptors cannot poison the index', () {
    expect(AudioRegion.fromJson({...region(0).toJson(), 'db': double.nan}), isNull);
    expect(AudioRegion.fromJson({...region(0).toJson(), 'mfcc': [1]}), isNull);
    expect(AudioRegion.fromJson({...region(0).toJson(), 'vocal': 2}), isNull);
  });
  test('legacy v1 data remains usable but is scheduled for upgrade', () {
    final legacy = TrackFeatures.fromJson({...fakeRecord('a', 0, 0, rev: 'r').toJson(), 'av': 1})!;
    expect(legacy.isCompatibleFor('r'), isTrue);
    expect(legacy.isCurrentFor('r'), isFalse);
    expect(legacy.sections, isNull);
    expect(legacy.isCompatibleFor('changed'), isFalse);
  });
  test('optional malformed section extension does not destroy legacy features', () {
    final f = TrackFeatures.fromJson({...fakeRecord('a', 0, 0).toJson(), 'sx': {'v': 1, 'regions': [null]}})!;
    expect(f.sections, isNull);
    expect(f.trackId, 'a');
  });
  test('vocal evidence needs reliable nonheuristic coverage', () {
    expect(SectionIndex([region(0, voice: 0.8, source: 'heuristic')]).at(0, 2000)!.vocalProbability, isNull);
    final known = SectionIndex([region(0, voice: 0.8, source: 'annotation')]).at(0, 2000)!;
    expect(known.vocalProbability, closeTo(0.8, 1e-9));
    expect(known.reliableVocals, isTrue);
  });
  test('analyzer extracts separate energy windows and bounded discontinuities', () {
    final frames = FrameSet.empty((12 * intelFps).ceil());
    for (var i = 0; i < frames.count; i++) {
      frames.rmsDb[i] = i < 4 * intelFps ? -12 : -40;
      frames.centroid[i] = 1500; frames.bass[i] = 0.3;
      for (var k = 0; k < 12; k++) {
        frames.mfcc[i * 12 + k] = i < 4 * intelFps ? 1 : 25;
        frames.chroma[i * 12 + k] = 1 / 12;
      }
    }
    final sx = analyzeSections(frames, Uint8List(12 * intelRate * 2));
    expect(sx.regions.length, 3);
    expect(sx.regions[0].energyDb, greaterThan(sx.regions[1].energyDb));
    expect(sx.regions[1].boundaryConfidence, greaterThan(0.4));
    expect(sx.regions.every((r) => r.valid), isTrue);
    expect(sx.regions.every((r) => r.vocalProbability == null), isTrue);
  });
}
