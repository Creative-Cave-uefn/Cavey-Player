import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/automix.dart';
import 'package:cave_player/core/mixbook.dart';

double _gap(int a, int b, double period) {
  final d = ((a - b) % period + period) % period;
  return math.min(d, period - d);
}

void main() {
  group('настройки перехода', () {
    test('JSON туда и обратно', () {
      const p = TransitionPref(
          mode: TransitionMode.manual, style: 'fade', bars: 16, seconds: 9, outMs: 120000, inMs: 4000, sync: false, bass: false, offsetMs: -35);
      final back = TransitionPref.fromJson(p.toJson())!;
      expect(back, p);
    });

    test('copyWith умеет очищать поля', () {
      const p = TransitionPref(mode: TransitionMode.manual, outMs: 5000, inMs: 100);
      expect(p.copyWith(outMs: null).outMs, isNull);
      expect(p.copyWith(outMs: null).inMs, 100);
      expect(p.copyWith(bars: 4).outMs, 5000);
    });

    test('мусор в файле не ломает чтение', () {
      expect(TransitionPref.fromJson('x'), isNull);
      final p = TransitionPref.fromJson({'m': 'что-то', 'b': 9999, 'of': 9999})!;
      expect(p.mode, TransitionMode.auto);
      expect(p.bars, 64);
      expect(p.offsetMs, 300);
    });
  });

  group('книга переходов', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mixbook'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('сохраняется в файл и читается заново', () {
      final f = File('${dir.path}/t.json');
      final a = MixBook(f);
      a.set('x', 'y', const TransitionPref(mode: TransitionMode.cut));
      a.set('y', 'z', const TransitionPref(mode: TransitionMode.manual, bars: 4));
      a.flush();
      final b = MixBook(f);
      expect(b.count, 2);
      expect(b.get('x', 'y')!.mode, TransitionMode.cut);
      expect(b.get('y', 'z')!.bars, 4);
      expect(b.get('y', 'x'), isNull, reason: 'пара упорядочена: обратный переход — другой');
    });

    test('автоматический переход не хранится, сброс удаляет', () {
      final book = MixBook(File('${dir.path}/t.json'));
      book.set('x', 'y', const TransitionPref(mode: TransitionMode.manual));
      expect(book.count, 1);
      book.set('x', 'y', const TransitionPref(mode: TransitionMode.auto));
      expect(book.count, 0);
      book.set('x', 'y', const TransitionPref(mode: TransitionMode.cut));
      book.remove('x', 'y');
      expect(book.count, 0);
    });

    test('слушатели узнают об изменении', () {
      final book = MixBook(File('${dir.path}/t.json'));
      var n = 0;
      book.addListener(() => n++);
      book.set('x', 'y', const TransitionPref(mode: TransitionMode.cut));
      book.set('x', 'y', const TransitionPref(mode: TransitionMode.cut)); // то же самое: без шума
      book.remove('x', 'y');
      expect(n, 2);
    });
  });

  group('ручной план', () {
    const out = MixProfile(
        durationMs: 240000, introMs: 0, outroMs: 230000, endMs: 236000, loudDb: -12, v: 3, bpm: 120, headBeatMs: 200, tailBeatMs: 130);
    const inn = MixProfile(
        durationMs: 200000, introMs: 700, outroMs: 190000, endMs: 198000, loudDb: -12, v: 3, bpm: 124, headBeatMs: 420, tailBeatMs: 130);

    test('начало, заданное вручную, встаёт на доле; длина — в тактах', () {
      final plan = MixPlan.manual(out, inn, const TransitionPref(mode: TransitionMode.manual, bars: 4, outMs: 100000));
      expect(plan.dj, isTrue);
      expect(_gap(plan.start.inMilliseconds, 130, 500), lessThan(1));
      expect((plan.start.inMilliseconds - 100000).abs(), lessThan(250));
      expect(plan.length.inMilliseconds, 8000);
      expect(plan.rate, closeTo(120 / 124, 1e-9));
      expect(plan.swapAt, const Duration(milliseconds: 4000));
    });

    test('вход следующего, заданный вручную, тоже на его доле', () {
      final plan = MixPlan.manual(out, inn, const TransitionPref(mode: TransitionMode.manual, inMs: 30000));
      expect(_gap(plan.inStart.inMilliseconds, 420, 60000 / 124), lessThan(2));
      expect((plan.inStart.inMilliseconds - 30000).abs(), lessThan(300));
    });

    test('плавный стиль: без подгонки темпа, длина в секундах, как задали', () {
      final plan = MixPlan.manual(out, inn, const TransitionPref(mode: TransitionMode.manual, style: 'fade', seconds: 6, outMs: 50000, inMs: 2000));
      expect(plan.dj, isFalse);
      expect(plan.rate, 1.0);
      expect(plan.start.inMilliseconds, 50000);
      expect(plan.length.inMilliseconds, 6000);
      expect(plan.inStart.inMilliseconds, 2000);
      expect(plan.swapAt, isNull);
    });

    test('без подгонки темпа скорость не меняется', () {
      final plan = MixPlan.manual(out, inn, const TransitionPref(mode: TransitionMode.manual, sync: false));
      expect(plan.rate, 1.0);
    });

    test('без обмена басов его нет', () {
      final plan = MixPlan.manual(out, inn, const TransitionPref(mode: TransitionMode.manual, bass: false));
      expect(plan.swapAt, isNull);
    });

    test('переход не выходит за конец уходящего трека', () {
      final plan = MixPlan.manual(out, inn, const TransitionPref(mode: TransitionMode.manual, bars: 32, outMs: 238000));
      expect((plan.start + plan.length).inMilliseconds, lessThanOrEqualTo(out.durationMs));
      expect(plan.length.inMilliseconds, greaterThanOrEqualTo(500));
    });

    test('нет сетки долей: DJ-стиль превращается в плавный, но начало и вход — как заданы', () {
      const noGrid = MixProfile(durationMs: 200000, introMs: 700, outroMs: 190000, endMs: 198000, loudDb: -12, v: 3);
      final plan = MixPlan.manual(noGrid, inn, const TransitionPref(mode: TransitionMode.manual, bars: 4, outMs: 100000, inMs: 1234));
      expect(plan.dj, isFalse);
      expect(plan.start.inMilliseconds, 100000);
      expect(plan.inStart.inMilliseconds, 1234);
      expect(plan.length.inMilliseconds, 8000); // 4 такта по 2 с, пока темпа нет
    });

    test('без заданного начала берётся автоматическое', () {
      final auto = MixPlan.make(out, inn, dj: const DjMix(bars: 8));
      final plan = MixPlan.manual(out, inn, const TransitionPref(mode: TransitionMode.manual, bars: 8), auto: auto);
      expect((plan.start.inMilliseconds - auto.start.inMilliseconds).abs(), lessThan(2));
    });
  });
}
