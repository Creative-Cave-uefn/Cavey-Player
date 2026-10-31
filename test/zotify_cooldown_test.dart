import 'dart:io';

import 'package:cave_player/core/dl/zotify_cooldown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 31, 12);
  test('Retry-After pause survives restart and expires without requesting login', () async {
    final dir = await Directory.systemTemp.createTemp('zotify-cooldown');
    try {
      final file = File('${dir.path}/state.json');
      final first = ZotifyCooldown();
      final error = await first.pause('90', stateFile: file, now: now);
      expect(error.serverProvided, isTrue);
      expect(first.until, now.add(const Duration(seconds: 90)));
      final reopened = ZotifyCooldown();
      await expectLater(reopened.check(stateFile: file, now: now.add(const Duration(seconds: 89))), throwsA(isA<ZotifyRateLimit>()));
      await reopened.check(stateFile: file, now: now.add(const Duration(seconds: 91)));
    } finally { await dir.delete(recursive: true); }
  });
  test('HTTP-date is respected; missing or invalid header uses a local pause', () async {
    final api = ZotifyCooldown();
    await api.pause(HttpDate.format(now.add(const Duration(minutes: 2))), now: now);
    expect(api.until, now.add(const Duration(minutes: 2)));
    final missing = await ZotifyCooldown().pause(null, now: now);
    expect(missing.serverProvided, isFalse);
    expect(missing.until, now.add(const Duration(minutes: 1)));
    final invalid = await ZotifyCooldown().pause('invalid', now: now);
    expect(invalid.serverProvided, isFalse);
  });
  test('A later shorter response does not shorten an existing pause', () async {
    final state = ZotifyCooldown();
    await state.pause('90', now: now);
    await state.pause('1', now: now.add(const Duration(seconds: 10)));
    expect(state.until, now.add(const Duration(seconds: 90)));
  });
}
