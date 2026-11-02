import 'dart:io';
import 'dart:typed_data';

import 'package:cave_player/core/covers.dart';
import 'package:cave_player/core/drive.dart';
import 'package:cave_player/core/library.dart';
import 'package:flutter_test/flutter_test.dart';

class _Drive implements DriveApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Library implements LibraryController {
  final Uint8List image;
  var loads = 0;
  _Library(this.image);

  @override
  Future<Uint8List> downloadCover(String fileId) async {
    loads++;
    return image;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Cinema cover uses cached thumbnail while fetching full resolution', () async {
    final dir = await Directory.systemTemp.createTemp('cave-cover-cinema-');
    try {
      final bytes = await File('test/fixtures/cover.jpg').readAsBytes();
      final lib = _Library(bytes);
      final covers = CoverService(_Drive(), lib, dir);

      await covers.forFile('album-cover', px: 160);
      expect(covers.hasExactFile('album-cover', px: 160), isTrue);
      expect(covers.hasExactFile('album-cover', px: 1100), isFalse);
      final preview = covers.peekFile('album-cover', px: 1100);
      expect(preview, isNotNull, reason: 'fullscreen must show an existing small thumbnail');
      await covers.forFile('album-cover', px: 1100);
      expect(covers.hasExactFile('album-cover', px: 1100), isTrue);
      expect(covers.peekFile('album-cover', px: 1100), isNotNull);
      // Original image was already cached to disk by thumbnail generation.
      expect(lib.loads, 1);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
