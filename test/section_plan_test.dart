import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/automix.dart';
import 'package:cave_player/core/intel/adaptive_dj.dart';
import 'package:cave_player/core/intel/record.dart';
import 'package:cave_player/core/intel/sections.dart';
import 'package:cave_player/core/intel/set_context.dart';
import 'adaptive_dj_test.dart' show song;

AdaptiveTrack sectional(String id, {bool badIntro = false, double voice = 0.1, bool measured = false,
    bool stable = true, double onsets = 2, String artist = '', String genre = ''}) {
  final old = song(id, stable: stable);
  final index = SectionIndex([
    for (var t = 0; t < 240000; t += 4000)
      AudioRegion(startMs: t, endMs: t + 4000,
          energyDb: badIntro && t < 16000 ? -45 : -22,
          centroidHz: badIntro && t < 16000 ? 7000 : 1500,
          bassRatio: 0.3, onsetDensity: onsets, activeFraction: 1,
          mfcc: List.filled(12, badIntro && t < 16000 ? 30.0 : 1.0),
          chroma: List.filled(12, 1 / 12), boundaryConfidence: t % 16000 == 0 ? 0.8 : 0,
          samplePeakDb: -9, vocalProbability: measured ? voice : null,
          vocalConfidence: measured ? 0.95 : null, vocalSource: measured ? 'annotation' : 'unknown'),
  ]);
  final f = TrackFeatures.fromJson({...old.features!.toJson(), 'sx': index.toJson()})!;
  return AdaptiveTrack(id, old.profile, f, artist: artist, genre: genre);
}

void main() {
  test('local cue matching chooses the suitable incoming region, not global intro stats', () {
    final d = AdaptiveDj.pair(sectional('a'), sectional('b', badIntro: true));
    expect(d.plan!.inStart.inMilliseconds, greaterThanOrEqualTo(16000));
    expect(d.components, contains('timbre'));
    expect(d.components, contains('harmony'));
  });
  test('section plans stay within both source files and respect stretch bounds', () {
    final d = AdaptiveDj.pair(sectional('a'), sectional('b'));
    expect(d.plan!.start + d.plan!.length, lessThanOrEqualTo(const Duration(milliseconds: 238000)));
    expect(d.plan!.inStart.inMilliseconds + (d.plan!.length.inMilliseconds * d.plan!.rate), lessThanOrEqualTo(238000));
    expect((d.plan!.rate - 1).abs(), lessThanOrEqualTo(0.08));
  });
  test('reliable double vocal evidence cannot produce a long overlay', () {
    final d = AdaptiveDj.pair(sectional('a', measured: true, voice: 0.9), sectional('b', measured: true, voice: 0.9));
    expect(d.plan!.length.inMilliseconds, lessThanOrEqualTo(2000));
    expect(d.components['vocalRisk'], 1);
  });
  test('unstable rhythm never enables a section beat blend', () {
    final d = AdaptiveDj.pair(sectional('a', stable: false), sectional('b'));
    expect(d.plan!.dj, isFalse);
    expect(d.plan!.rate, 1);
  });
  test('manual section planning evaluates the current region, not the distant tail', () {
    final d = AdaptiveDj.choose(sectional('a'), [sectional('b')], manualPositionMs: 60000, earliestMs: 62000);
    expect(d.plan!.start.inMilliseconds, inInclusiveRange(60000, 69000));
    expect(d.components, contains('energy'));
  });
  test('late requests preserve a safe fallback without invalid negative lengths', () {
    final d = AdaptiveDj.pair(sectional('a'), sectional('b'), earliestMs: 239000);
    expect(d.technique, AdaptiveTechnique.autoMix);
    expect(d.plan!.length, greaterThan(Duration.zero));
  });
  test('joint search and lookahead remain deterministic with full sections', () {
    final pool = [sectional('b'), sectional('c', badIntro: true), sectional('d')];
    final a = AdaptiveDj.choose(sectional('a'), pool);
    final b = AdaptiveDj.choose(sectional('a'), pool);
    expect(a.toJson(), b.toJson());
    expect(a.path.toSet().length, 3);
  });
  test('set context penalizes repeated artist and repeated transition technique', () {
    const context = DjSetContext(history: [DjHistoryEntry('a', artist: 'same', technique: 'beatBlend', energyDb: -20)]);
    final repeat = context.score(const DjHistoryEntry('b', artist: 'same', technique: 'beatBlend', energyDb: -20));
    final fresh = context.score(const DjHistoryEntry('b', artist: 'new', technique: 'cut', energyDb: -20));
    expect(fresh, greaterThan(repeat));
  });
  test('rise and relax choose opposite physical energy trajectories', () {
    const past = [DjHistoryEntry('a', energyDb: -20)];
    const up = DjHistoryEntry('b', energyDb: -18.5), down = DjHistoryEntry('c', energyDb: -21.5);
    const rise = DjSetContext(intent: SetIntent.rise, history: past), relax = DjSetContext(intent: SetIntent.relax, history: past);
    expect(rise.score(up), greaterThan(rise.score(down)));
    expect(relax.score(down), greaterThan(relax.score(up)));
  });
  test('context snapshots are immutable and bounded to eight entries', () {
    var context = const DjSetContext();
    final original = context;
    for (var i = 0; i < 12; i++) { context = context.append(DjHistoryEntry('$i', energyDb: -20)); }
    expect(original.history, isEmpty);
    expect(context.history.length, 8);
    expect(context.history.first.id, '4');
  });
}
