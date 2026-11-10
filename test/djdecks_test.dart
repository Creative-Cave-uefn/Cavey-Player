import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/automix.dart';
import 'package:cave_player/core/djdecks.dart';

MixProfile _p({double? bpm, int? head, int? tail, int? headBar}) => MixProfile(
      durationMs: 240000,
      introMs: 0,
      outroMs: 220000,
      endMs: 238000,
      loudDb: -14,
      v: MixProfile.version,
      bpm: bpm,
      headBeatMs: head,
      tailBeatMs: tail,
      headBarMs: headBar,
    );

void main() {
  group('сетка долей из профиля', () {
    test('нет темпа или якоря — нет сетки', () {
      expect(DjDecks.gridOf(null), isNull);
      expect(DjDecks.gridOf(_p(head: 100)), isNull);
      expect(DjDecks.gridOf(_p(bpm: 120)), isNull);
    });

    test('якорь — начало такта, если оно известно', () {
      final g = DjDecks.gridOf(_p(bpm: 120, head: 600, headBar: 100))!;
      expect(g.anchorMs, 100);
      expect(g.barKnown, isTrue);
      expect(g.bpm, closeTo(120, 1e-9));
    });

    test('темп уточняется по хвосту трека', () {
      // Настоящий темп 120,1: за 400 долей набегает около 170 мс
      final period = 60000 / 120.1;
      final tail = (100 + 400 * period).round();
      final g = DjDecks.gridOf(_p(bpm: 120, head: 100, tail: tail))!;
      expect(g.bpm, closeTo(120.1, 0.01));
    });

    test('не сходится на целое число долей — оставляем как есть', () {
      final g = DjDecks.gridOf(_p(bpm: 120, head: 100, tail: 100 + 400 * 500 + 250))!;
      expect(g.bpm, 120);
    });

    test('короткий промежуток не трогаем', () {
      final g = DjDecks.gridOf(_p(bpm: 120, head: 100, tail: 9000))!;
      expect(g.bpm, 120);
    });
  });
}
