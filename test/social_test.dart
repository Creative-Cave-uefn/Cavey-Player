import 'package:cave_player/core/social.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> status(DateTime updated, {bool playing = true, String? v}) => {
      'email': 'a@x.com',
      'name': 'A',
      'updated': updated.toUtc().toIso8601String(),
      if (v != null) 'v': v,
      'now': {'id': 't1', 't': 'Песня', 'a': 'Исполнитель', 'p': playing, 'pos': 1000, 'at': updated.toUtc().toIso8601String()},
    };

void main() {
  tearDown(() => Member.skew = Duration.zero);

  test('Свежий статус считается «слушает сейчас»', () {
    final m = Member.fromJson(status(DateTime.now().toUtc().subtract(const Duration(seconds: 20))));
    expect(m.live, isTrue);
  });

  test('Старый статус — не «слушает сейчас», но «недавно был»', () {
    final m = Member.fromJson(status(DateTime.now().toUtc().subtract(const Duration(minutes: 5))));
    expect(m.live, isFalse);
    expect(m.recent, isTrue);
  });

  test('Поправка на часы: если свои часы спешат на 5 минут, статус по времени Диска всё равно свежий', () {
    // Время Диска на 5 минут меньше нашего локального
    final serverNow = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final m = Member.fromJson(status(serverNow));
    expect(m.live, isFalse);
    Member.skew = const Duration(minutes: -5);
    expect(m.live, isTrue);
  });

  test('Версия приложения читается из статуса; у старых версий её нет', () {
    expect(Member.fromJson(status(DateTime.now(), v: '0.2.51')).version, '0.2.51');
    expect(Member.fromJson(status(DateTime.now())).version, '');
  });
}
