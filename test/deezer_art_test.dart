import 'dart:async';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/deezer_art.dart';

void main() {
  group('Deezer artwork selection', () {
    test('successful lookup resolves immediately and deduplicates concurrent calls', () async {
      // Regression: returning _inflight.remove(key) from whenComplete caused
      // the Future to wait on itself, even after the cover had been cached.
      final completion = Completer<DeezerArtwork?>();
      final cover = DeezerArtwork(Uint8List.fromList([1, 2, 3]), 1000, 1000, 'LookupTestAlbum');
      var requests = 0;
      Future<DeezerArtwork?> loader() {
        requests++;
        return completion.future;
      }
      final first = DeezerArt.find(
        artist: 'LookupTestArtist', title: 'LookupTestSong',
        album: 'LookupTestAlbum', lookupForTest: loader);
      final second = DeezerArt.find(
        artist: 'LookupTestArtist', title: 'LookupTestSong',
        album: 'LookupTestAlbum', lookupForTest: loader);
      expect(requests, 1);
      completion.complete(cover);
      expect(await first.timeout(const Duration(seconds: 1)), same(cover));
      expect(await second.timeout(const Duration(seconds: 1)), same(cover));
      final cached = await DeezerArt.find(
        artist: 'LookupTestArtist', title: 'LookupTestSong',
        album: 'LookupTestAlbum', lookupForTest: () => throw StateError('cache not used'));
      expect(cached, same(cover));
      expect(requests, 1);
    });

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

    test('fills title, performer and album from an exact Deezer match', () {
      final searchResponse = <String, dynamic>{
        'data': [
          {
            'artist': {'name': 'Different Artist'},
            'title': 'All I Need',
            'title_short': 'All I Need',
            'album': {'title': 'Different Album'},
          },
          {
            'artist': {'name': 'Radiohead'},
            'title': 'All I Need',
            'title_short': 'All I Need',
            'album': {'title': 'In Rainbows'},
          },
        ],
      };
      final metadata = DeezerArt.metadataFromSearch(
        searchResponse, artist: 'radioHEAD', title: 'All I Need');
      expect(metadata?.title, 'All I Need');
      expect(metadata?.artist, 'Radiohead');
      expect(metadata?.album, 'In Rainbows');
    });

    test('prefers the album hint for multiple editions of one song', () {
      final data = <String, dynamic>{
        'data': [
          {
            'artist': {'name': 'Radiohead'},
            'title': 'All I Need',
            'title_short': 'All I Need',
            'album': {'title': 'Live Collection'},
          },
          {
            'artist': {'name': 'Radiohead'},
            'title': 'All I Need',
            'title_short': 'All I Need',
            'album': {'title': 'In Rainbows'},
          },
        ],
      };
      final meta = DeezerArt.metadataFromSearch(data,
          artist: 'Radiohead', title: 'All I Need', album: 'in rainbows');
      expect(meta?.album, 'In Rainbows');
    });

    test('does not overwrite tags from an unrelated track', () {
      final payload = <String, dynamic>{
        'data': [
          {
            'artist': {'name': 'Radiohead'},
            'title': 'Weird Fishes/Arpeggi',
            'title_short': 'Weird Fishes/Arpeggi',
            'album': {'title': 'In Rainbows'},
          },
        ],
      };
      expect(DeezerArt.metadataFromSearch(payload,
          artist: 'Radiohead', title: 'All I Need'), isNull);
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
