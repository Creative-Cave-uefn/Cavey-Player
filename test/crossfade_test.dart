import 'package:cave_player/core/crossfade.dart';
import 'package:cave_player/core/media_keys.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const total = Duration(minutes: 3);
  Duration at(int s, [int ms = 0]) => Duration(seconds: s, milliseconds: ms);

  group('Когда начинать плавный переход', () {
    test('Выключен (0 секунд) — никогда', () {
      expect(crossfadeDue(seconds: 0, duration: total, position: at(178), previous: at(177, 800)), isFalse);
    });

    test('Граница N секунд до конца пройдена при обычном воспроизведении — пора', () {
      // трек 180 с, переход 3 с: граница на 177-й секунде
      expect(crossfadeDue(seconds: 3, duration: total, position: at(177, 100), previous: at(176, 900)), isTrue);
    });

    test('До границы ещё далеко и после неё уже прошли — не начинаем снова', () {
      expect(crossfadeDue(seconds: 3, duration: total, position: at(100), previous: at(99, 800)), isFalse);
      expect(crossfadeDue(seconds: 3, duration: total, position: at(178), previous: at(177, 800)), isFalse);
    });

    test('Перемотка в конец трека (большой скачок позиции) перехода не включает', () {
      expect(crossfadeDue(seconds: 3, duration: total, position: at(178), previous: at(40)), isFalse);
      expect(crossfadeDue(seconds: 3, duration: total, position: at(177, 500), previous: at(60)), isFalse);
    });

    test('Перемотка назад не считается', () {
      expect(crossfadeDue(seconds: 3, duration: total, position: at(100), previous: at(177, 500)), isFalse);
    });

    test('Короткий трек (меньше 2·N секунд) переходом не затихает', () {
      expect(crossfadeDue(seconds: 5, duration: at(9), position: at(4, 500), previous: at(4, 300)), isFalse);
      expect(crossfadeDue(seconds: 5, duration: at(10), position: at(5, 100), previous: at(4, 900)), isTrue);
    });
  });

  group('Кривая громкости перехода', () {
    test('В начале слышен только уходящий, в конце только приходящий', () {
      final a = fadeGains(0);
      expect(a.$1, closeTo(1, 1e-9));
      expect(a.$2, closeTo(0, 1e-9));
      final b = fadeGains(1);
      expect(b.$1, closeTo(0, 1e-9));
      expect(b.$2, closeTo(1, 1e-9));
    });

    test('Посередине общая мощность не проваливается, значения за границами обрезаются', () {
      final m = fadeGains(0.5);
      expect(m.$1 * m.$1 + m.$2 * m.$2, closeTo(1, 1e-9));
      expect(fadeGains(-3).$1, closeTo(1, 1e-9));
      expect(fadeGains(7).$2, closeTo(1, 1e-9));
    });
  });

  group('Кому достаются медиаклавиши', () {
    final now = DateTime(2026, 10, 31, 12);
    bool owned({bool enabled = true, bool hasTrack = true, bool playing = false, DateTime? pausedAt}) =>
        mediaKeysOwned(enabled: enabled, hasTrack: hasTrack, playing: playing, pausedAt: pausedAt, now: now);

    test('Пока трек играет — нам, даже если фоном что-то ещё', () {
      expect(owned(playing: true), isTrue);
    });
    test('Выключено в настройках или нет трека — не нам', () {
      expect(owned(enabled: false, playing: true), isFalse);
      expect(owned(hasTrack: false, playing: true), isFalse);
    });
    test('После паузы ещё 10 минут нам (чтобы продолжить клавишей), потом отдаём другим', () {
      expect(owned(pausedAt: now.subtract(const Duration(minutes: 3))), isTrue);
      expect(owned(pausedAt: now.subtract(const Duration(minutes: 11))), isFalse);
      expect(owned(), isFalse);
    });
  });
}
