import 'dart:typed_data';

import 'package:image/image.dart' as img;

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
    test('decodes a Deezer cover without capturing caller UI callbacks', () async {
      // A former Isolate.run closure captured the search logger and Flutter
      // widget tree, causing an unsendable-object error for every valid image.
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 96, height: 72)),
      );
      final local = DeezerArt.dimensions(bytes);
      expect(local, (96, 72));
      final background = await DeezerArt.dimensionsInBackground(bytes);
      expect(background, (96, 72));
    });

    test('worker rejects corrupt images without throwing', () async {
      final invalid = Uint8List.fromList([0, 1, 2, 3]);
      expect(await DeezerArt.dimensionsInBackground(invalid), isNull);
    });

    test('logs invalid search parameters without issuing network requests', () async {
      final messages = <String>[];
      final artwork = await DeezerArt.find(
        artist: '',
        title: 'All I Need',
        onLog: messages.add,
      );
      expect(artwork, isNull);
      expect(messages, isNotEmpty);
      expect(messages.join('\n'), contains('Пустые параметры'));
      expect(messages.join('\n'), contains('All I Need'));
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
