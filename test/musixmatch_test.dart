import 'dart:convert';

import 'package:cave_player/core/musixmatch.dart';
import 'package:cave_player/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final rich = [
    {'ts': 10.0, 'te': 12.0, 'l': [{'c': 'При', 'o': 0.0}, {'c': 'вет мир', 'o': 0.5}]},
  ];
  test('RichSync preserves characters and relative segment times', () {
    final result = Musixmatch.parse(rich)!;
    expect(result.origin, 'musixmatch');
    expect(result.lines.single.text, 'Привет мир');
    final words = result.lines.single.words!;
    expect(words.first.start.inMilliseconds, 10000);
    expect(words.first.end.inMilliseconds, 10500);
    expect(words.last.start.inMilliseconds, 10500);
    expect(words.last.end.inMilliseconds, 12000);
    expect(words.last.from, 3);
    expect(words.last.to, 10);
    expect(result.indexAt(const Duration(seconds: 11)), 0);
    expect(result.indexAt(Duration.zero), -1); // seek back before the first line
  });
  test('Missing and invalid timings do not create fake word sync', () {
    expect(Musixmatch.parse({}), isNull);
    expect(Musixmatch.parse([{'ts': 3, 'te': 2, 'l': []}]), isNull);
    expect(Musixmatch.parse([{'ts': 1, 'te': 2, 'l': [{'c': 'x', 'o': -1}]}]), isNull);
  });
  test('Search rejects a wrong recording and requests richsync for a matching track', () async {
    final requested = <Uri>[];
    final client = MockClient((request) async {
      requested.add(request.url);
      final path = request.url.path;
      if (path == '/search') return http.Response('<script src="/_next/static/chunks/pages/_app-test.js"></script>', 200);
      if (path.endsWith('.js')) {
        final key = base64.encode(utf8.encode('test-key')).split('').reversed.join();
        return http.Response('from("$key".split', 200);
      }
      Map body;
      if (path.endsWith('track.search')) {
        body = {'track_list': [
          {'track': {'track_id': 1, 'track_name': 'Song', 'artist_name': 'Artist', 'track_length': 400}},
          {'track': {'track_id': 2, 'track_name': 'Song', 'artist_name': 'Artist', 'track_length': 100}},
        ]};
      } else {
        expect(request.url.queryParameters['track_id'], '2');
        expect(request.url.queryParameters['signature'], isNotEmpty);
        body = {'richsync': {'richsync_body': jsonEncode(rich)}};
      }
      return http.Response(jsonEncode({'message': {'header': {'status_code': 200}, 'body': body}}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final track = Track(id: 'id', source: 's', title: 'Song', artist: 'Artist', album: '', albumArtist: '',
        no: null, year: '', pic: null, cover: null, modified: '', size: 0, by: '', path: '');
    final result = await Musixmatch(client).find(track, const Duration(seconds: 100));
    expect(result?.lines.single.text, 'Привет мир');
    expect(requested.where((u) => u.path.endsWith('track.richsync.get')).length, 1);
    client.close();
  });
}
