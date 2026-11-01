import 'dart:convert';

import 'package:cave_player/core/backend/cavey_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('new API requires HTTPS and never accepts URL credentials', () {
    expect(
      () => CaveyApiClient(baseUrl: Uri.parse('http://example.invalid')),
      throwsArgumentError,
    );
    expect(
      () => CaveyApiClient(baseUrl: Uri.parse('https://user:pass@example.invalid')),
      throwsArgumentError,
    );
  });

  test('Google ID token is exchanged in POST body, never in URL', () async {
    final api = CaveyApiClient(
      baseUrl: Uri.parse('https://api.cavey.example'),
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/auth/google');
        expect(request.url.query, isEmpty);
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(jsonDecode(request.body)['id_token'], 'id-token-from-google');
        return http.Response(jsonEncode({
          'user_id': 'usr-stable',
          'access_token': 'cavey-access',
          'refresh_token': 'cavey-refresh',
        }), 200);
      }),
    );
    final session = await api.exchangeGoogleIdToken('id-token-from-google');
    expect(session.userId, 'usr-stable');
    expect(session.accessToken, 'cavey-access');
    api.dispose();
  });

  test('snapshot retains legacy Drive track IDs and playlists', () async {
    const driveId = '1OldGoogleDriveFileId';
    final library = <String, dynamic>{
      'v': 1,
      'sources': [],
      'tracks': {
        driveId: {'s': 'legacy-folder', 't': 'Song', 'al': 'Album'},
      },
      'playlists': [
        {'id': 'p', 'name': 'Favorites', 'by': 'old@example.com', 'at': 1,
         'items': [driveId]},
      ],
      'likes': {driveId: ['old@example.com']},
      'members': {'old@example.com': 'Legacy member'},
      'edits': {},
      'hidden': [],
    };
    final api = CaveyApiClient(
      baseUrl: Uri.parse('https://api.cavey.example/'),
      tokenProvider: () async => 'cavey-session',
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/libraries/legacy-library/snapshot');
        expect(request.headers['Authorization'], 'Bearer cavey-session');
        return http.Response(jsonEncode({
          'revision': 'rev1',
          'library': library,
        }), 200);
      }),
    );
    final snapshot = await api.fetchLibrary('legacy-library');
    expect(snapshot.revision, 'rev1');
    expect((snapshot.library['tracks'] as Map).containsKey(driveId), isTrue);
    expect(((snapshot.library['playlists'] as List).single as Map)['items'], [driveId]);
    expect((snapshot.library['likes'] as Map)[driveId], ['old@example.com']);
    api.dispose();
  });

  test('mutations preserve exact operation payload and idempotency key', () async {
    final operations = [
      {'op': 'like', 'id': 'old-drive-track-id', 'email': 'old@example.com', 'on': true},
    ];
    final api = CaveyApiClient(
      baseUrl: Uri.parse('https://api.cavey.example'),
      tokenProvider: () async => 'session',
      client: MockClient((request) async {
        expect(request.url.path, '/v1/libraries/library-1/operations');
        final body = jsonDecode(request.body) as Map;
        expect(body['base_revision'], 'rev1');
        expect(body['mutation_id'], 'device-1-operation-1');
        expect(body['operations'], operations);
        return http.Response(jsonEncode({
          'revision': 'rev2',
          'library': {'v': 1},
        }), 200);
      }),
    );
    final snapshot = await api.commitOperations('library-1',
      baseRevision: 'rev1',
      mutationId: 'device-1-operation-1',
      operations: operations,
    );
    expect(snapshot.revision, 'rev2');
    api.dispose();
  });

  test('revision conflict fails without overwriting another device', () async {
    final api = CaveyApiClient(
      baseUrl: Uri.parse('https://api.cavey.example'),
      tokenProvider: () async => 'session',
      client: MockClient((_) async => http.Response('conflict', 409)),
    );
    await expectLater(
      () => api.commitOperations('library-1',
        baseRevision: 'stale',
        mutationId: 'op-1',
        operations: [{'op': 'setMeta'}],
      ),
      throwsA(isA<CaveyApiException>().having(
        (e) => e.statusCode, 'statusCode', 409,
      )),
    );
    api.dispose();
  });
}
