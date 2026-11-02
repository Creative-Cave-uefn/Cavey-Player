import 'package:cave_player/core/covers.dart';
import 'package:cave_player/core/models.dart';
import 'package:cave_player/ui/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('Cinema requests original artwork even in a 360px-wide panel', () {
    expect(CoverImage.requestedPhysicalPixels(
      size: 360, devicePixelRatio: 1.0, originalQuality: true), 0);
    expect(CoverService.bucketFor(CoverImage.requestedPhysicalPixels(
      size: 360, devicePixelRatio: 1.0, originalQuality: true)), 0);
    expect(CoverImage.requestedPhysicalPixels(
      size: 360, devicePixelRatio: 1.0), 360);
    expect(CoverService.bucketFor(360), 640);
  });

  test('Fullscreen requests original quality but immediately reuses thumbnail', () {
    expect(CoverService.bucketFor(1100), 0);
    expect(CoverService.previewBucketPriority(1100), [0, 640, 160]);
    expect(CoverService.previewBucketPriority(160), [160, 640, 0]);
  });

  test('Small cover may fall back to 640px or original', () {
    expect(CoverService.bucketFor(160), 160);
    expect(CoverService.previewBucketPriority(160), [160, 640, 0]);
  });

  test('Medium cover may show smaller preview until 640px is ready', () {
    expect(CoverService.bucketFor(520), 640);
    expect(CoverService.previewBucketPriority(520), [640, 0, 160]);
  });
}
