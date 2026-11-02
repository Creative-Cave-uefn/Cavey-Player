import 'package:cave_player/core/covers.dart';
import 'package:cave_player/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

void main() {
  test('Image recovery rejects MP3 bodies or invalid range responses', () {
    expect(CoverService.looksLikeImage(
      Uint8List.fromList([0x49, 0x44, 0x33, ...List<int>.filled(40, 0)])), isFalse);
    expect(CoverService.looksLikeImage(
      Uint8List.fromList([0xff, 0xd8, 0xff, ...List<int>.filled(40, 0)])), isTrue);
    expect(CoverService.looksLikeImage(
      Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, ...List<int>.filled(40, 0)])), isTrue);
  });

  test('New albums without embedded art are eligible for Deezer recovery', () {
    Track track({String artist = 'Slipknot', String title = 'Before I Forget',
        String album = 'Vol. 3: (The Subliminal Verses)'}) => Track(
      id: 'new-file', source: 'drive-folder',
      title: title, artist: artist, album: album, albumArtist: '',
      no: null, year: '', pic: null, cover: null, modified: '',
      size: 123, by: '', path: '',
    );
    expect(track().hasCover, isFalse);
    expect(CoverService.canFindInDeezer(track()), isTrue);
    expect(CoverService.canFindInDeezer(track(
      artist: '', title: '', album: '')), isFalse);
  });

  test('Cover copies: 160 and 640 for lists, the original only for large views', () {
    expect(CoverService.bucketFor(160), 160);
    expect(CoverService.bucketFor(360), 640);
    expect(CoverService.bucketFor(520), 640);
    expect(CoverService.bucketFor(1100), 0);
  });
}
