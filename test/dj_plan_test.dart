import 'dart:typed_data';

import 'package:cave_player/core/automix.dart';
import 'package:cave_player/core/intel/dj_plan.dart';
import 'package:cave_player/core/intel/record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'intel_test.dart' show fakeRecord;

// Темп 120: доля 500 мс, такт 2000 мс, фраза из 8 тактов — 16 000 мс.

MixProfile profile({int intro = 1000}) => MixProfile(
      durationMs: 240000,
      introMs: intro,
      outroMs: 220000,
      endMs: 238000,
      loudDb: -14,
      bpm: 120,
      headBeatMs: 0,
      tailBeatMs: 0,
      headBarMs: 0,
      tailBarMs: 0,
      key: '8A',
    );

Uint8List curve(int seconds, int v, {int loudUntil = 0, int loud = 95}) =>
    Uint8List.fromList([for (var i = 0; i < seconds; i++) i < loudUntil ? loud : v]);

DjData djData({bool stable = true, double conf = 0.8, int vocal = 10, Uint8List? energy}) => DjData(
      gridBpm: 120,
      firstBeatMs: 0,
      barAnchorMs: 0,
      headBeatMs: 0,
      tailBeatMs: 0,
      headBarMs: 0,
      tailBarMs: 0,
      driftMs: 5,
      gridStable: stable,
      phrasesMs: [for (var t = 0; t <= 240000; t += 16000) t],
      phraseBars: 8,
      phraseConf: conf,
      energyCurve: energy ?? curve(240, 80, loudUntil: 40),
      vocalCurve: Uint8List.fromList(List<int>.filled(240, vocal)),
    );

TrackFeatures withDj(String id, DjData d, {double? lufs}) {
  final f = fakeRecord(id, 1, 0);
  return TrackFeatures.fromJson({...f.toJson(), 'dj': d.toJson(), if (lufs != null) 'lu': lufs})!;
}

MixPlan basePlan() {
  final p = MixPlan.make(profile(), profile(), dj: const DjMix(bars: 8));
  expect(p.dj, isTrue, reason: 'тестовые профили должны давать DJ-план');
  return p;
}

void main() {
  test('базовый план из тестовых профилей: 8 тактов, начало на такте', () {
    final p = basePlan();
    expect(p.length.inMilliseconds, 16000);
    expect(p.start.inMilliseconds % 2000, 0);
  });

  test('начало переходит на границу фразы и остаётся на такте', () {
    final base = basePlan();
    final r = DjPlanner.refine(base, profile(), profile(), withDj('a', djData()), withDj('b', djData()), allowCut: false);
    expect(r.kind, DjKind.blend);
    expect(r.plan.start.inMilliseconds % 16000, 0);
    expect(r.plan.start.inMilliseconds, lessThanOrEqualTo(base.start.inMilliseconds));
    expect(base.start.inMilliseconds - r.plan.start.inMilliseconds, lessThanOrEqualTo(8 * 2000));
    expect(r.plan.length, base.length);
    expect(r.plan.inStart.inMilliseconds % 2000, 0);
  });

  test('без разбора, с нестабильной сеткой или без фаз план не меняется', () {
    final base = basePlan();
    final a = withDj('a', djData()), b = withDj('b', djData());
    expect(identical(DjPlanner.refine(base, profile(), profile(), null, b).plan, base), isTrue);
    expect(identical(DjPlanner.refine(base, profile(), profile(), a, null).plan, base), isTrue);
    final shaky = withDj('s', djData(stable: false));
    expect(DjPlanner.refine(base, profile(), profile(), shaky, b).kind, DjKind.unchanged);
    final plain = MixPlan.make(profile(), profile());
    expect(DjPlanner.refine(plain, profile(), profile(), a, b).kind, DjKind.unchanged);
    // фразы не определены: начало не сдвигается
    final guess = withDj('g', djData(conf: 0.0));
    final r = DjPlanner.refine(base, profile(), profile(), guess, guess, allowCut: false);
    expect(r.plan.start, base.start);
  });

  test('вокал у обоих: наложение сокращается до двух тактов', () {
    final base = basePlan();
    final a = withDj('a', djData(vocal: 80)), b = withDj('b', djData(vocal: 80));
    final r = DjPlanner.refine(base, profile(), profile(), a, b, allowCut: false);
    expect(r.kind, DjKind.blend);
    expect(r.plan.length.inMilliseconds, 4000);
    expect(r.plan.swapAt?.inMilliseconds, 2000);
    // конец перехода не сместился относительно фразового начала более чем на такт-кратное
    expect((r.plan.start.inMilliseconds + r.plan.length.inMilliseconds) % 2000, 0);
  });

  test('резкий стык: вокал мешает, разрешено — стык на границе фразы', () {
    final base = basePlan();
    final a = withDj('a', djData(vocal: 80)), b = withDj('b', djData(vocal: 80));
    final r = DjPlanner.refine(base, profile(), profile(), a, b);
    expect(r.kind, DjKind.cut);
    expect(r.plan.length.inMilliseconds, lessThanOrEqualTo(500));
    expect(r.plan.start.inMilliseconds % 16000, 0);
    expect(r.plan.start.inMilliseconds, lessThanOrEqualTo(238000 - 500));
    expect(r.plan.swapAt, isNull);
    expect(r.plan.dj, isTrue);
  });

  test('резкий стык: оба на полной энергии', () {
    final base = basePlan();
    final full = curve(240, 95);
    final a = withDj('a', djData(energy: full)), b = withDj('b', djData(energy: full));
    final r = DjPlanner.refine(base, profile(), profile(), a, b);
    expect(r.kind, DjKind.cut);
    // если запретить, получается обычный переход по фразе
    final off = DjPlanner.refine(base, profile(), profile(), a, b, allowCut: false);
    expect(off.kind, DjKind.blend);
  });

  test('тихий конец уходящего: резкого стыка нет', () {
    final base = basePlan();
    // громкость уходящего у конца ниже его громкой части: энергия не «полная», вокала нет
    final r = DjPlanner.refine(base, profile(), profile(), withDj('a', djData()), withDj('b', djData()));
    expect(r.kind, DjKind.blend);
  });

  test('громкость выравнивается по LUFS и ограничена 6 дБ', () {
    final base = basePlan();
    final a = withDj('a', djData(), lufs: -10), b = withDj('b', djData(), lufs: -13);
    final r = DjPlanner.refine(base, profile(), profile(), a, b, allowCut: false);
    expect(r.plan.inGain, closeTo(1.4125, 0.01));
    final far = DjPlanner.refine(base, profile(), profile(), withDj('a', djData(), lufs: -8), withDj('b', djData(), lufs: -24), allowCut: false);
    expect(far.plan.inGain, closeTo(1.9953, 0.01));
  });
}
