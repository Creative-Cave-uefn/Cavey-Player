import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/tags.dart';

/// Читает фикстуру так же, как Диск отдаёт куски файла
Future<int?> probe(String name) {
  final b = File('test/fixtures/$name').readAsBytesSync();
  return probeDurationMs((s, e) async => Uint8List.fromList(b.sublist(s, e + 1)), b.length);
}

void main() {
  group('длительность по кускам файла', () {
    for (final name in ['a.mp3', 'b.mp3', 'c.flac', 'd.opus', 'e.m4a', 'f.ogg']) {
      test(name, () async {
        final ms = await probe(name);
        expect(ms, isNotNull, reason: 'длительность $name должна определиться');
        expect(ms!, closeTo(3000, 100));
      });
    }

    test('не звук — не угадываем', () async {
      final junk = Uint8List.fromList(List.generate(5000, (i) => i % 7));
      expect(await probeDurationMs((s, e) async => Uint8List.fromList(junk.sublist(s, e + 1)), junk.length), isNull);
      expect(await probeDurationMs((s, e) async => Uint8List(0), 0), isNull);
    });
  });
}
