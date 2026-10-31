import 'package:cave_player/core/social.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Счётчик за всё время собирается из прослушиваний по дням', () {
    final t = playTotalsFrom({
      '2026-10-30': {'a': 2, 'b': 1},
      '2026-10-31': {'a': 1},
    });
    expect(t, {'a': 3, 'b': 1});
  });

  test('Наслушанное время: считается реальный шаг воспроизведения', () {
    const s = Duration(seconds: 1);
    expect(listenStep(playing: true, before: const Duration(seconds: 10), now: const Duration(seconds: 11)), s);
    // Пауза, перемотка вперёд и назад ничего не добавляют
    expect(listenStep(playing: false, before: const Duration(seconds: 10), now: const Duration(seconds: 11)), Duration.zero);
    expect(listenStep(playing: true, before: const Duration(seconds: 10), now: const Duration(seconds: 90)), Duration.zero);
    expect(listenStep(playing: true, before: const Duration(seconds: 90), now: const Duration(seconds: 10)), Duration.zero);
    expect(listenStep(playing: true, before: const Duration(seconds: 10), now: const Duration(seconds: 10)), Duration.zero);
  });

  test('Сумма прослушанного', () {
    expect(listenedSum([60000, 30000, 30000]), const Duration(minutes: 2));
    expect(listenedSum(const []), Duration.zero);
  });

  test('Подпись времени', () {
    expect(formatListened(const Duration(minutes: 45)), '45 мин');
    expect(formatListened(const Duration(hours: 1, minutes: 20)), '1 ч 20 мин');
    expect(formatListened(const Duration(hours: 12, minutes: 5)), '12 ч');
    expect(formatListened(const Duration(hours: 3)), '3 ч');
  });

  test('Старый файл без метки учёта обнуляется', () {
    final m = Member.fromJson({
      'email': 'a@b.c',
      'plays': {
        '2026-10-31': {'x': 2}
      },
      'tc': {'x': 40},
    });
    expect(m.totals, isEmpty);
    expect(m.plays, isEmpty);
    expect(m.timeTotals, isEmpty);
  });

  test('Новый файл: прослушивания и время читаются', () {
    final m = Member.fromJson({
      'email': 'a@b.c',
      'lv': kListenVersion,
      'plays': {
        '2026-10-31': {'x': 2}
      },
      'tc': {'x': 5},
      'lt': {
        '2026-10-31': {'x': 90000}
      },
      'ltc': {'x': 120000},
    });
    expect(m.totals, {'x': 5});
    expect(m.plays['2026-10-31'], {'x': 2});
    expect(m.time['2026-10-31'], {'x': 90000});
    expect(m.timeTotals, {'x': 120000});
  });

  test('Новый файл без общего счётчика: считаем по дням', () {
    final m = Member.fromJson({
      'email': 'a@b.c',
      'lv': kListenVersion,
      'plays': {
        '2026-10-31': {'x': 2}
      },
    });
    expect(m.totals, {'x': 2});
  });
}
