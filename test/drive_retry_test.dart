import 'dart:io';

import 'package:cave_player/core/auth.dart';
import 'package:cave_player/core/drive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Accounts implements AccountManager {
  @override
  Future<String> token(String email, {bool force = false}) async => 'test-token';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Drive GET retries connection closed before response headers', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      if (attempts == 1) {
        throw http.ClientException(
            'Connection closed before full header was received', request.url);
      }
      return http.Response('{"files":[]}', 200);
    });
    final api = DriveApi(_Accounts(), client: client);
    final response = await api.send('test@example.com', 'GET', DriveApi.api('files'));
    expect(response.statusCode, 200);
    expect(attempts, 2);
    client.close();
  });

  test('Drive upload requests never replay after ambiguous disconnect', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      throw http.ClientException('Connection closed before headers', request.url);
    });
    final api = DriveApi(_Accounts(), client: client);
    await expectLater(
      api.send('test@example.com', 'POST', DriveApi.api('files'),
          body: <int>[1, 2, 3]),
      throwsA(isA<DriveException>().having((e) => e.status, 'status', 503)),
    );
    expect(attempts, 1);
    client.close();
  });

  test('Drive GET does not retry permission failures', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      return http.Response('{"error":{"message":"Forbidden"}}', 403);
    });
    final api = DriveApi(_Accounts(), client: client);
    await expectLater(api.send('test@example.com', 'GET', DriveApi.api('files')),
        throwsA(isA<DriveException>().having((e) => e.status, 'status', 403)));
    expect(attempts, 1);
    client.close();
  });
  test('Drive Changes skips unrelated changes but catches changed child files', () async {
    var pages = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/changes/startPageToken')) {
        return http.Response('{"startPageToken":"cursor0"}', 200);
      }
      pages++;
      if (pages == 1) {
        return http.Response(
          '{"nextPageToken":"cursor1","changes":[{"fileId":"other","file":{"parents":["outside"]}}]}',
          200);
      }
      return http.Response(
        '{"newStartPageToken":"cursor2","changes":[{"fileId":"newAudio","file":{"parents":["nestedMusic"]}}]}',
        200);
    });
    final api = DriveApi(_Accounts(), client: client);
    expect(await api.startPageToken('test@example.com'), 'cursor0');
    final changes = await api.changesSince('test@example.com', 'cursor0');
    expect(pages, 2);
    expect(changes.nextCursor, 'cursor2');
    expect(changes.affects({'oldAudio'}, {'musicRoot'}), isFalse);
    expect(changes.affects({'oldAudio'}, {'musicRoot', 'nestedMusic'}), isTrue);
    client.close();
  });

  test('Drive Changes marks incomplete file metadata as requiring a full scan', () async {
    final client = MockClient((request) async => http.Response(
        '{"newStartPageToken":"next","changes":[{"fileId":"newUnknown","removed":false}]}',
        200));
    final changes = await DriveApi(_Accounts(), client: client)
        .changesSince('test@example.com', 'before');
    expect(changes.unknown, isTrue);
    expect(changes.affects(<String>{}, {'musicRoot'}), isTrue);
    client.close();
  });

  test('Audio cache continues a matching partial file using Content-Range', () async {
    final directory = await Directory.systemTemp.createTemp('cave-range-');
    try {
      final target = File('${directory.path}/track.audio');
      await File('${target.path}.part').writeAsString('abc');
      await File('${target.path}.part.version').writeAsString('revision1');
      final seen = <String?>[];
      final client = MockClient((request) async {
        seen.add(request.headers['range']);
        return http.Response('def', 206,
            headers: {'content-range': 'bytes 3-5/6'});
      });
      final api = DriveApi(_Accounts(), client: client);
      await api.downloadToFile('test@example.com', 'file1', target,
          expectedModified: 'revision1');
      expect(await target.readAsString(), 'abcdef');
      expect(seen, ['bytes=3-']);
      expect(await File('${target.path}.part').exists(), isFalse);
      expect(await File('${target.path}.part.version').exists(), isFalse);
      client.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('Server returning HTTP 200 to resumed request replaces old part', () async {
    final directory = await Directory.systemTemp.createTemp('cave-full-');
    try {
      final target = File('${directory.path}/track.audio');
      await File('${target.path}.part').writeAsString('OLD');
      await File('${target.path}.part.version').writeAsString('revision1');
      final client = MockClient((request) async =>
          http.Response('NEWFILE', 200));
      await DriveApi(_Accounts(), client: client).downloadToFile(
          'test@example.com', 'file2', target, expectedModified: 'revision1');
      expect(await target.readAsString(), 'NEWFILE');
      client.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('Changed source revision discards stale partial audio', () async {
    final directory = await Directory.systemTemp.createTemp('cave-version-');
    try {
      final target = File('${directory.path}/track.audio');
      await File('${target.path}.part').writeAsString('STALE');
      await File('${target.path}.part.version').writeAsString('oldRevision');
      final seen = <String?>[];
      final client = MockClient((request) async {
        seen.add(request.headers['range']);
        return http.Response('fresh', 200);
      });
      await DriveApi(_Accounts(), client: client).downloadToFile(
          'test@example.com', 'file3', target, expectedModified: 'newRevision');
      expect(seen, [null]);
      expect(await target.readAsString(), 'fresh');
      client.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

}
