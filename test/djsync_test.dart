import 'package:flutter_test/flutter_test.dart';

import 'package:cave_player/core/dj.dart';
import 'package:cave_player/core/djsync.dart';

void main() {
  group('BeatGrid', () {
    const g = BeatGrid(120, 100); // доля раз в 500 мс, первая на 100 мс

    test('номера и времена долей', () {
      expect(g.periodMs, 500);
      expect(g.beatAt(600), closeTo(1, 1e-9));
      expect(g.timeOf(3), closeTo(1600, 1e-9));
    });

    test('прижатие к долям', () {
      expect(g.snap(340), closeTo(100, 1e-9));
      expect(g.snap(360), closeTo(600, 1e-9));
      expect(g.nextBeat(601), closeTo(1100, 1e-9));
      expect(g.nextBar(101), closeTo(2100, 1e-9));
      expect(g.phaseAt(350), closeTo(0.5, 1e-9));
    });
  });

  group('syncRatio', () {
    test('обычный темп', () {
      final r = syncRatio(128, 124);
      expect(r.k, 1);
      expect(r.ratio, closeTo(128 / 124, 1e-9));
    });

    test('двойной и половинный темп', () {
      // ведущий 80, второй 160: доли второго вдвое чаще, темп менять не надо
      final a = syncRatio(80, 160);
      expect(a.k, 2);
      expect(a.ratio, closeTo(1.0, 1e-9));
      // ведущий 160, второй 82: второй играет вполовину реже, подтягиваем 82 → 80
      final b = syncRatio(160, 82);
      expect(b.k, 0.5);
      expect(b.ratio, closeTo(80 / 82, 1e-9));
    });
  });

  group('фаза', () {
    test('треки уже на одной фазе — сдвиг нулевой', () {
      const m = BeatGrid(120, 0), s = BeatGrid(120, 50);
      expect(phaseShiftMs(m, 1000, s, 1050, 1), closeTo(0, 1e-6));
    });

    test('второй трек опережает на 100 мс — надо отступить', () {
      const m = BeatGrid(120, 0), s = BeatGrid(120, 0);
      expect(phaseShiftMs(m, 1000, s, 1100, 1), closeTo(-100, 1e-6));
      expect(phaseShiftMs(m, 1000, s, 900, 1), closeTo(100, 1e-6));
    });

    test('сдвиг не больше половины доли', () {
      const m = BeatGrid(100, 0), s = BeatGrid(100, 0);
      for (var off = -290.0; off <= 290; off += 37) {
        expect(phaseShiftMs(m, 6000, s, 6000 + off, 1).abs(), lessThanOrEqualTo(300 + 1e-6));
      }
    });
  });

  group('тональность', () {
    test('сдвиг на полутон меняет номер на 7', () {
      expect(shiftKey(const Camelot(8, false), 1), const Camelot(3, false));
      expect(shiftKey(const Camelot(8, false), -1), const Camelot(1, false));
      expect(shiftKey(const Camelot(8, true), 12), const Camelot(8, true));
    });

    test('подходящие тональности не трогаем', () {
      expect(keyShiftFor(const Camelot(8, true), const Camelot(8, true)), 0);
      expect(keyShiftFor(const Camelot(8, true), const Camelot(9, true)), 0);
      expect(keyShiftFor(null, const Camelot(1, true)), 0);
    });

    test('неподходящие сдвигаем на минимум', () {
      // 8A и 3A: через сдвиг на −1 полутон 3A → 8A (3 − 7 = −4 → 8)
      expect(keyShiftFor(const Camelot(8, true), const Camelot(3, true)), -1);
      // 8A и 2A → за пределами ±3 не вылечить? 2A − 7·s: s=1 → 7A, подходит
      final s = keyShiftFor(const Camelot(8, true), const Camelot(2, true));
      expect(s.abs(), lessThanOrEqualTo(3));
      expect(Camelot.compat(const Camelot(8, true), shiftKey(const Camelot(2, true), s)), greaterThanOrEqualTo(0.85));
    });
  });

  test('длина перехода', () {
    expect(transitionMs(120, 8), 16000);
    expect(transitionMs(null, 8), 8000);
    expect(transitionMs(60, 64), 45000);
    expect(transitionMs(200, 1), 4000);
  });

  test('петля по долям', () {
    const g = BeatGrid(120, 0);
    final (a, b) = loopSpan(g, 1010, 4);
    expect(a, closeTo(1000, 1e-9));
    expect(b, closeTo(3000, 1e-9));
  });

  test('регулятор эквалайзера', () {
    expect(eqKnobToDb(-1), -26);
    expect(eqKnobToDb(0), 0);
    expect(eqKnobToDb(1), 6);
  });
}
