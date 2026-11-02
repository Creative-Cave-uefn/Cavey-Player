import 'package:cave_player/core/covers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
