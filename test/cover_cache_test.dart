import 'dart:typed_data';

import 'package:cave_player/core/covers.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _jpeg({bool complete = true, int pad = 0}) {
  final b = <int>[0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(40, 7)];
  if (complete) b.addAll([0xFF, 0xD9]);
  b.addAll(List.filled(pad, 0));
  return Uint8List.fromList(b);
}

Uint8List _png({bool complete = true}) {
  final b = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(40, 3)];
  if (complete) b.addAll([0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]);
  return Uint8List.fromList(b);
}

void main() {
  group('looksComplete', () {
    test('accepts finished JPEG and PNG', () {
      expect(CoverService.looksComplete(_jpeg()), isTrue);
      expect(CoverService.looksComplete(_png()), isTrue);
    });

    test('tolerates zero padding after JPEG end marker', () {
      expect(CoverService.looksComplete(_jpeg(pad: 6)), isTrue);
    });

    test('rejects a write cut short', () {
      expect(CoverService.looksComplete(_jpeg(complete: false)), isFalse);
      expect(CoverService.looksComplete(_png(complete: false)), isFalse);
      expect(CoverService.looksComplete(Uint8List(0)), isFalse);
      expect(CoverService.looksComplete(Uint8List.fromList([0xFF, 0xD8])), isFalse);
    });

    test('does not judge formats it does not know', () {
      expect(CoverService.looksComplete(Uint8List.fromList(List.filled(64, 9))), isTrue);
    });
  });

  group('bucketFor', () {
    test('uses the 160px copy only when it is not stretched', () {
      expect(CoverService.bucketFor(160), 160);
      expect(CoverService.bucketFor(161), 640);
      expect(CoverService.bucketFor(200), 640);
    });

    test('keeps 640px up to 720 and the original above', () {
      expect(CoverService.bucketFor(720), 640);
      expect(CoverService.bucketFor(721), 0);
      expect(CoverService.bucketFor(0), 0);
    });
  });
}
