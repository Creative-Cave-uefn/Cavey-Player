import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/deezer_art.dart';

void main() {
  group('Deezer artwork selection', () {
    test('compares pixels without discarding the larger cover', () {
      final high = DeezerArtwork(Uint8List(0), 1200, 1200, 'Album');
      expect(high.betterThan(640, 640), isTrue);
      expect(high.betterThan(1600, 1600), isFalse);
      expect(high.betterThan(1600, 600), isFalse);
      expect(high.betterThan(1200, 1200), isFalse);
    });
    test('matches only normalized artist and album metadata', () {
      expect(DeezerArt.same('Daft Punk', 'DAFT  PUNK'), isTrue);
      expect(DeezerArt.same('Album: Vol. 1', 'Album Vol 1'), isTrue);
      expect(DeezerArt.same('Artist A', 'Artist B'), isFalse);
      expect(DeezerArt.same('', 'Artist'), isFalse);
      expect(DeezerArt.dimensions(Uint8List(0)), isNull);
    });
  });
}
