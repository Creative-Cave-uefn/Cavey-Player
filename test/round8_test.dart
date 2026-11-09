import 'package:cave_player/core/ntfy.dart';
import 'package:cave_player/core/player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Быстрый канал', () {
    test('без связи отправлять нельзя, лимит не выставлен', () {
      final ch = NtfyChannel(server: 'https://example.invalid', topic: 't', onMessage: (_) {});
      expect(ch.canSend, isFalse);
      expect(ch.limited, isFalse);
    });

    test('слишком длинное сообщение не уходит, а вызывающий узнаёт об этом', () async {
      final ch = NtfyChannel(server: 'https://example.invalid', topic: 't', onMessage: (_) {});
      final ok = await ch.send({'x': 'я' * 3000});
      expect(ok, isFalse);
    });
  });

  group('Полоса подсветки', () {
    test('яркость никогда не растёт и в конце равна нулю', () {
      final t0 = DateTime(2026, 1, 1, 12);
      for (final (from, len, dur) in [(0.2, 8000, 200000), (0.95, 4000, 240000), (0.5, 0, 0), (0.8, 6000, 0)]) {
        final info = CrossfadeInfo(from, t0, len, oldDurationMs: dur);
        var prev = 1.0;
        for (var ms = 0; ms <= info.totalMs + 200; ms += 20) {
          final a = info.alpha(t0.add(Duration(milliseconds: ms)));
          expect(a, lessThanOrEqualTo(prev + 1e-12), reason: '$from $len $dur @$ms');
          prev = a;
        }
        expect(prev, 0.0);
      }
    });
  });
}
