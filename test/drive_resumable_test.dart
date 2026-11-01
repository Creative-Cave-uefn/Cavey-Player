import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/drive.dart';

void main() {
  group('Google Drive resumable replacement', () {
    test('uses valid 256 KiB aligned chunks and a bounded request duration', () {
      expect(DriveApi.mediaChunkBytes % (256 * 1024), 0);
      expect(DriveApi.mediaChunkTimeout, const Duration(seconds: 90));
    });

    test('resumes at the byte after the confirmed Range', () {
      expect(DriveApi.resumableOffset('bytes=0-1048575', 2097152), 1048576);
      expect(DriveApi.resumableOffset('bytes=0-262143', 1048576), 262144);
      expect(DriveApi.resumableOffset(null, 2097152), 0);
    });

    test('rejects malformed and out-of-bounds acknowledgements', () {
      expect(() => DriveApi.resumableOffset('bytes=100-199', 500), throwsA(isA<DriveException>()));
      expect(() => DriveApi.resumableOffset('bytes=0-1000', 1000), throwsA(isA<DriveException>()));
      expect(() => DriveApi.resumableOffset('garbage', 1000), throwsA(isA<DriveException>()));
    });
  });
}
