import 'dart:typed_data';

import 'package:cave_player/core/covers.dart';
import 'package:cave_player/core/image_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Test artwork: a diagonal gradient between two colours, [size] px square
Uint8List _art(int size, {int r = 200, int g = 40, int b = 60, bool png = false}) {
  final im = img.Image(width: size, height: size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final k = (x + y) / (2 * size);
      im.setPixelRgb(x, y, (r * (1 - k) + 20 * k).round(), (g * (1 - k) + 200 * k).round(), (b * (1 - k) + 120 * k).round());
    }
  }
  return Uint8List.fromList(png ? img.encodePng(im) : img.encodeJpg(im, quality: 80));
}

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

  group('sameArtwork', () {
    test('same cover at another size and format counts as the same', () async {
      expect(await sameArtwork(_art(250), _art(1000, png: true)), isTrue);
      expect(await sameArtwork(_art(500), _art(1000)), isTrue);
    });

    test('a different cover is not swapped in', () async {
      expect(await sameArtwork(_art(500), _art(1000, r: 20, g: 200, b: 220)), isFalse);
    });

    test('unreadable data is never the same', () async {
      expect(await sameArtwork(Uint8List.fromList([1, 2, 3]), _art(500)), isFalse);
    });
  });
}
