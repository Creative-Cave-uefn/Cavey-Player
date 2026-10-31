import 'dart:convert';
import 'dart:io';

import 'package:cave_player/core/musixmatch.dart';
import 'package:cave_player/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response response(Map body, [int status = 200]) => http.Response(jsonEncode({
  'message': {'header': {'status_code': status}, 'body': body},
}), 200, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  final track = Track(id: 'id', source: 's', title: 'Song', artist: 'Artist', album: '', albumArtist: '',
      no: null, year: '', pic: null, cover: null, modified: '', size: 0, by: '', path: '');
  final match = {'track': {'track_name': 'Song', 'artist_name': 'Artist', 'commontrack_id': 42, 'track_length': 100}};
  final rich = [{'ts': 10.0, 'te': 12.0, 'x': 'Привет мир', 'l': [{'c': 'Привет', 'o': 0.0}, {'c': 'мир', 'o': 0.5}]}];
  test('RichSync preserves whitespace and relative word timestamps', () {
    final lyrics = Musixmatch.parse(rich)!;
    expect(lyrics.lines.single.text, 'Привет мир');
    final words = lyrics.lines.single.words!;
    expect(words.first.start.inMilliseconds, 10000);
    expect(words.first.end.inMilliseconds, 10500);
    expect(words.last.from, 7);
    expect(words.last.end.inMilliseconds, 12000);
    expect(lyrics.indexAt(Duration.zero), -1);
    expect(lyrics.indexAt(const Duration(seconds: 11)), 0);
    expect(Musixmatch.parse([{'ts': 1, 'te': 2, 'l': [{'c': 'x', 'o': -1}]}]), isNull);
  });
  test('Payload without te retains the word start times', () {
    final lyrics = Musixmatch.parse([{'ts': 10, 'x': 'a b', 'l': [{'c': 'a', 'o': 0}, {'c': 'b', 'o': 1}]}])!;
    expect(lyrics.lines.single.words!.last.start.inSeconds, 11);
    expect(lyrics.lines.single.text, 'a b');
  });
  test('New host, matched commontrack ID and persistent token reuse', () async {
    final dir = await Directory.systemTemp.createTemp('mx-token');
    var tokenCalls = 0;
    final client = MockClient((request) async {
      expect(request.url.host, 'apic-desktop.musixmatch.com');
      expect(request.url.queryParameters.containsKey('signature'), isFalse);
      if (request.url.path.endsWith('token.get')) { tokenCalls++; return response({'user_token': 'test-token'}); }
      expect(request.url.queryParameters['usertoken'], 'test-token');
      if (request.url.path.endsWith('matcher.track.get')) return response(match);
      expect(request.url.queryParameters['commontrack_id'], '42');
      return response({'richsync': {'richsync_body': jsonEncode(rich)}});
    });
    try {
      final file = File('${dir.path}/token.json');
      final first = Musixmatch(client, tokenFile: file);
      expect((await first.find(track, const Duration(seconds: 100)))?.lines.single.text, 'Привет мир');
      await first.find(track, const Duration(seconds: 100));
      await Musixmatch(client, tokenFile: file).find(track, const Duration(seconds: 100));
      expect(tokenCalls, 1);
    } finally { client.close(); await dir.delete(recursive: true); }
  });
  test('One refresh on invalid token, with no endless retry', () async {
    var tokens = 0, matches = 0;
    final client = MockClient((r) async {
      if (r.url.path.endsWith('token.get')) return response({'user_token': 'token-${++tokens}'});
      matches++;
      return response({}, 401);
    });
    await expectLater(Musixmatch(client).find(track, Duration.zero), throwsA(isA<MusixmatchFailure>()));
    expect(tokens, 2);
    expect(matches, 2);
    client.close();
  });
  test('HTML and rate limits are errors and token requests are cooled down', () async {
    for (final status in [200, 429]) {
      var calls = 0;
      final client = MockClient((r) async { calls++; return http.Response('<html>Site Unavailable</html>', status); });
      final api = Musixmatch(client);
      await expectLater(api.find(track, Duration.zero), throwsA(isA<MusixmatchFailure>()));
      await expectLater(api.find(track, Duration.zero), throwsA(isA<MusixmatchFailure>()));
      expect(calls, 1);
      client.close();
    }
  });
  test('Wrong version is rejected; missing RichSync falls back to line timing', () async {
    final client = MockClient((r) async {
      if (r.url.path.endsWith('token.get')) return response({'user_token': 't'});
      if (r.url.path.endsWith('matcher.track.get')) return response(match);
      if (r.url.path.endsWith('track.richsync.get')) return response({}, 404);
      return response({'subtitle_list': [{'subtitle': {'subtitle_body': '[00:10.00]Example'}}]});
    });
    final api = Musixmatch(client);
    expect(await api.find(track, const Duration(seconds: 200)), isNull);
    final lyrics = await api.find(track, const Duration(seconds: 100));
    expect(lyrics?.lines.single.text, 'Example');
    expect(lyrics?.synced, isTrue);
    expect(lyrics?.lines.single.words, isNull);
    client.close();
  });
}
