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

  test('Наслушанное время: прослушивания × длительность', () {
    final d = estimateListened({'a': 3, 'b': 2}, (id) => id == 'a' ? const Duration(minutes: 4) : assumedTrackLength);
    expect(d, const Duration(minutes: 19));
  });

  test('Подпись времени', () {
    expect(formatListened(const Duration(minutes: 45)), '45 мин');
    expect(formatListened(const Duration(hours: 1, minutes: 20)), '1 ч 20 мин');
    expect(formatListened(const Duration(hours: 12, minutes: 5)), '12 ч');
    expect(formatListened(const Duration(hours: 3)), '3 ч');
  });

  test('Старый файл без счётчика: берём прослушивания за дни', () {
    final m = Member.fromJson({
      'email': 'a@b.c',
      'plays': {
        '2026-10-31': {'x': 2}
      },
    });
    expect(m.totals, {'x': 2});
    final n = Member.fromJson({
      'email': 'a@b.c',
      'plays': {
        '2026-10-31': {'x': 2}
      },
      'tc': {'x': 40},
    });
    expect(n.totals, {'x': 40});
  });
}
