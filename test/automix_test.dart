import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/automix.dart';

void main() {
  // 50 мс на точку: 2 с тишины, 60 с громко (-10 дБ), 6 с затихание до -40, 2 с тишины
  List<double> track() => [
        for (var i = 0; i < 40; i++) -120.0,
        for (var i = 0; i < 1200; i++) -10.0 + (i % 7 == 0 ? -3 : 0),
        for (var i = 0; i < 120; i++) -10.0 - 30 * i / 120,
        for (var i = 0; i < 40; i++) -120.0,
      ];

  test('профиль: тишина в начале, затихание и конец', () {
    final p = MixProfile.fromEnvelope(track())!;
    expect(p.introMs, 2000);
    expect(p.endMs, closeTo(68000, 1500)); // до -42 дБ от пика ещё слышно
    expect(p.outroMs, inInclusiveRange(62000, 64500));
    expect(p.loudDb, closeTo(-10, 1.5));
  });

  test('план: переход в затихании, следующий без тишины, громкость выровнена', () {
    final a = MixProfile.fromEnvelope(track())!;
    const b = MixProfile(durationMs: 200000, introMs: 1500, outroMs: 190000, endMs: 198000, loudDb: -16);
    final plan = MixPlan.make(a, b, maxSec: 8);
    expect(plan.start.inMilliseconds, a.endMs - plan.length.inMilliseconds);
    expect(plan.length.inMilliseconds, inInclusiveRange(1500, 8000));
    expect(plan.inStart, const Duration(milliseconds: 1500));
    expect(plan.inGain, greaterThan(1)); // следующий тише — поднимаем
  });

  test('план под такт при известном темпе', () {
    const a = MixProfile(durationMs: 200000, introMs: 0, outroMs: 193000, endMs: 199000, loudDb: -10);
    const b = MixProfile(durationMs: 200000, introMs: 0, outroMs: 190000, endMs: 198000, loudDb: -10);
    final plan = MixPlan.make(a, b, maxSec: 10, bpm: 120); // такт — 2 с
    expect(plan.length.inMilliseconds % 2000, 0);
    expect(plan.inGain, closeTo(1, 0.001));
  });
}
