import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/intel/adaptive_dj.dart';
import 'package:cave_player/core/intel/record.dart';
import 'package:cave_player/core/intel/sections.dart';
import 'package:cave_player/core/intel/set_context.dart';
import 'package:cave_player/core/automix.dart';
import 'package:cave_player/core/intel/section_plan.dart';
import 'package:cave_player/core/intel/rhythm.dart';
import 'adaptive_dj_test.dart' show song;

AdaptiveTrack sectional(String id,
    {bool badIntro = false,
    double voice = 0.1,
    bool measured = false,
    double peak = -9,
    bool stable = true,
    double onsets = 2,
    String artist = '',
    String genre = ''}) {
  final old = song(id, stable: stable);
  final index = SectionIndex([
    for (var t = 0; t < 240000; t += 4000)
      AudioRegion(
          startMs: t,
          endMs: t + 4000,
          energyDb: badIntro && t < 16000 ? -45 : -22,
          centroidHz: badIntro && t < 16000 ? 7000 : 1500,
          bassRatio: 0.3,
          onsetDensity: onsets,
          activeFraction: 1,
          mfcc: List.filled(12, badIntro && t < 16000 ? 30.0 : 1.0),
          chroma: List.filled(12, 1 / 12),
          boundaryConfidence: t % 16000 == 0 ? 0.8 : 0,
          samplePeakDb: peak,
          vocalProbability: measured ? voice : null,
          vocalConfidence: measured ? 0.95 : null,
          vocalSource: measured ? 'annotation' : 'unknown'),
  ]);
  final f = TrackFeatures.fromJson(
      {...old.features!.toJson(), 'sx': index.toJson()})!;
  return AdaptiveTrack(id, old.profile, f, artist: artist, genre: genre);
}

void main() {
  AdaptiveTrack keyed(String id, String key, {double confidence = 0.9}) {
    final track = sectional(id, measured: true);
    return AdaptiveTrack(
        id,
        track.profile,
        TrackFeatures.fromJson({
          ...track.features!.toJson(),
          'key': key,
          'kc': confidence,
        })!);
  }

  test('conflicting reliable keys cap overlays despite identical local chroma',
      () {
    final d = AdaptiveDj.pair(keyed('a', '8A'), keyed('b', '2B'));
    expect(d.components['keyCompatibility'], 0);
    expect(d.plan!.length.inMilliseconds, lessThanOrEqualTo(4000));
  });
  test('opt-in transposition is bounded and accounts for the outgoing pitch',
      () {
    final a = keyed('a', '8A'), b = keyed('b', '3A');
    final off = AdaptiveDj.pair(a, b);
    expect(off.plan!.transpose, 0);
    final on = AdaptiveDj.pair(a, b, options: const DjMix(transpose: true));
    expect(on.plan!.transpose, -1);
    expect(on.components['keyCompatibility'], 1);
    expect(on.plan!.tempoRamp, isTrue);
    final next = AdaptiveDj.pair(b, keyed('c', '8A'),
        options: const DjMix(transpose: true, outgoingShift: -1));
    expect(next.plan!.transpose, 0);
    expect(next.plan!.outgoingShift, -1);
    expect(next.components['keyCompatibility'], 1);
  });
  test('compatible keys permit a phrase-complete eight-bar mix', () {
    final a = keyed('a', '8A'), b = keyed('b', '9A');
    final d = AdaptiveDj.pair(a, b, options: const DjMix(bars: 8));
    expect(d.technique, AdaptiveTechnique.beatBlend);
    expect(d.plan!.length.inMilliseconds, 16000);
    expect(d.plan!.inStart.inMilliseconds % 16000, 0);
    expect((d.plan!.start + d.plan!.length).inMilliseconds % 16000, 0);
    expect(d.components['keyCompatibility'], 0.85);
    expect(d.components['durationFit'], 1);
  });
  test('weak key estimates do not veto a measured phrase mix', () {
    final d = AdaptiveDj.pair(
        keyed('a', '8A'), keyed('b', '2B', confidence: 0.2),
        options: const DjMix(bars: 8));
    expect(d.components, isNot(contains('keyCompatibility')));
    expect(d.plan!.length.inMilliseconds, 16000);
  });
  test('harmonic switch disables the key constraint', () {
    final d = AdaptiveDj.pair(keyed('a', '8A'), keyed('b', '2B'),
        options: const DjMix(bars: 8, harmonic: false));
    expect(d.components, isNot(contains('keyCompatibility')));
    expect(d.plan!.length.inMilliseconds, 16000);
  });
  test('observed local pulses obey key and phrase rules too', () {
    AdaptiveTrack local(AdaptiveTrack t, int start) {
      final timeline = RhythmTimeline([
        RhythmWindow(
          startMs: start,
          endMs: start + 24000,
          bpm: 120,
          confidence: 0.9,
          support: 1,
          residualMs: 2,
          beatsMs: [for (var ms = start; ms < start + 24000; ms += 500) ms],
          groove: List.filled(8, 0.5),
          lowGroove: List.filled(8, 0.5),
        )
      ]);
      return AdaptiveTrack(
          t.id,
          t.profile,
          TrackFeatures.fromJson({
            ...t.features!.toJson(),
            'rt': timeline.toJson(),
          })!);
    }

    final a = local(keyed('a', '8A'), 202000);
    final b = local(keyed('b', '8A'), 8000);
    final blend = AdaptiveDj.pair(a, b, options: const DjMix(bars: 8));
    expect(blend.plan!.dj, isTrue);
    expect(blend.plan!.length.inMilliseconds, 16000);
    expect((blend.plan!.start + blend.plan!.length).inMilliseconds % 16000, 0);
    final clash = AdaptiveDj.pair(a, local(keyed('c', '2B'), 8000),
        options: const DjMix(bars: 8));
    expect(clash.plan!.length.inMilliseconds, lessThanOrEqualTo(4000));
  });
  test('phrase preference never bypasses double-vocal safety', () {
    final d = AdaptiveDj.pair(sectional('a', measured: true, voice: 0.9),
        sectional('b', measured: true, voice: 0.9),
        options: const DjMix(bars: 8));
    expect(d.plan!.length.inMilliseconds, lessThanOrEqualTo(2000));
  });
  test('off-bar manual boundary cannot become an abrupt cut', () {
    final a = sectional('a', measured: true, voice: 0.9);
    final b = sectional('b', measured: true, voice: 0.9);
    final proposal = SectionPlanner.plan(
        a.planningProfile, b.planningProfile, a.features!, b.features!,
        options: const DjMix(),
        beatAllowed: true,
        manualPositionMs: 63200,
        allowCut: true);
    expect(proposal, isNotNull);
    if (proposal!.technique == 'cut') {
      expect(proposal.plan.start.inMilliseconds % 2000, 0);
      expect(proposal.plan.inStart.inMilliseconds % 2000, 0);
    }
  });
  test('cuts remain available on bars but reject off-bar section boundaries',
      () {
    final a = sectional('a', measured: true, voice: 0.9, peak: 0);
    final b = sectional('b', measured: true, voice: 0.9, peak: 0);
    expect(
        AdaptiveDj.pair(a, b, allowCut: true).technique, AdaptiveTechnique.cut);
    AdaptiveTrack shifted(AdaptiveTrack t) {
      final f = t.features!;
      return AdaptiveTrack(
          t.id,
          t.profile,
          TrackFeatures.fromJson({
            ...f.toJson(),
            'dj': {
              ...f.dj!.toJson(),
              'hbar': 250,
              'tbar': 250,
              'bar': 250,
              'ph': <int>[],
              'pc': 0
            },
          })!);
    }

    expect(AdaptiveDj.pair(shifted(a), shifted(b), allowCut: true).technique,
        isNot(AdaptiveTechnique.cut));
  });
  test(
      'local cue matching chooses the suitable incoming region, not global intro stats',
      () {
    final d = AdaptiveDj.pair(sectional('a'), sectional('b', badIntro: true));
    expect(d.plan!.inStart.inMilliseconds, greaterThanOrEqualTo(16000));
    expect(d.components, contains('timbre'));
    expect(d.components, contains('harmony'));
  });
  test('section plans stay within both source files and respect stretch bounds',
      () {
    final d = AdaptiveDj.pair(sectional('a'), sectional('b'));
    expect(d.plan!.start + d.plan!.length,
        lessThanOrEqualTo(const Duration(milliseconds: 238000)));
    expect(
        d.plan!.inStart.inMilliseconds +
            (d.plan!.length.inMilliseconds * d.plan!.rate),
        lessThanOrEqualTo(238000));
    expect((d.plan!.rate - 1).abs(), lessThanOrEqualTo(0.08));
  });
  test('reliable double vocal evidence cannot produce a long overlay', () {
    final d = AdaptiveDj.pair(sectional('a', measured: true, voice: 0.9),
        sectional('b', measured: true, voice: 0.9));
    expect(d.plan!.length.inMilliseconds, lessThanOrEqualTo(2000));
    expect(d.components['vocalRisk'], 1);
  });
  test('unstable rhythm never enables a section beat blend', () {
    final d = AdaptiveDj.pair(sectional('a', stable: false), sectional('b'));
    expect(d.plan!.dj, isFalse);
    expect(d.plan!.rate, 1);
  });
  test(
      'manual section planning evaluates the current region, not the distant tail',
      () {
    final d = AdaptiveDj.choose(sectional('a'), [sectional('b')],
        manualPositionMs: 60000, earliestMs: 62000);
    expect(d.plan!.start.inMilliseconds, inInclusiveRange(60000, 69000));
    expect(d.components, contains('energy'));
  });
  test(
      'late requests preserve a safe fallback without invalid negative lengths',
      () {
    final d =
        AdaptiveDj.pair(sectional('a'), sectional('b'), earliestMs: 239000);
    expect(d.technique, AdaptiveTechnique.autoMix);
    expect(d.plan!.length, greaterThan(Duration.zero));
  });
  test('joint search and lookahead remain deterministic with full sections',
      () {
    final pool = [
      sectional('b'),
      sectional('c', badIntro: true),
      sectional('d')
    ];
    final a = AdaptiveDj.choose(sectional('a'), pool);
    final b = AdaptiveDj.choose(sectional('a'), pool);
    expect(a.toJson(), b.toJson());
    expect(a.path.toSet().length, 3);
  });
  test(
      'set context penalizes repeated artist and repeated transition technique',
      () {
    const context = DjSetContext(history: [
      DjHistoryEntry('a', artist: 'same', technique: 'beatBlend', energyDb: -20)
    ]);
    final repeat = context.score(const DjHistoryEntry('b',
        artist: 'same', technique: 'beatBlend', energyDb: -20));
    final fresh = context.score(const DjHistoryEntry('b',
        artist: 'new', technique: 'cut', energyDb: -20));
    expect(fresh, greaterThan(repeat));
  });
  test('rise and relax choose opposite physical energy trajectories', () {
    const past = [DjHistoryEntry('a', energyDb: -20)];
    const up = DjHistoryEntry('b', energyDb: -18.5),
        down = DjHistoryEntry('c', energyDb: -21.5);
    const rise = DjSetContext(intent: SetIntent.rise, history: past),
        relax = DjSetContext(intent: SetIntent.relax, history: past);
    expect(rise.score(up), greaterThan(rise.score(down)));
    expect(relax.score(down), greaterThan(relax.score(up)));
  });
  test('context snapshots are immutable and bounded to eight entries', () {
    var context = const DjSetContext();
    final original = context;
    for (var i = 0; i < 12; i++) {
      context = context.append(DjHistoryEntry('$i', energyDb: -20));
    }
    expect(original.history, isEmpty);
    expect(context.history.length, 8);
    expect(context.history.first.id, '4');
  });
}
