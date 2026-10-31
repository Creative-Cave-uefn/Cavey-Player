import 'dart:convert';
import 'dart:io';

import 'package:cave_player/core/better_lyrics.dart';
import 'package:cave_player/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const sample = '<tt xmlns="http://www.w3.org/ns/ttml"><head><metadata><p>metadata only</p></metadata></head>'
    '<body><div><p begin="0:01.000" end="0:03.000">'
    '<span begin="1s" end="1.5s">При</span><span begin="1.5s" end="2s">вет</span> '
    '<span begin="2s" end="3s">мир</span></p></div></body></tt>';

void main() {
  final track = Track(id: 'id', source: 's', title: ' Example ', artist: 'Artist', album: 'Album', albumArtist: '',
      no: null, year: '', pic: null, cover: null, modified: '', size: 0, by: '', path: '');
  test('TTML preserves inter-span whitespace and syllable character ranges', () {
    final lyrics = BetterLyrics.parse(sample)!;
    expect(lyrics.origin, 'betterlyrics');
    expect(lyrics.synced, isTrue);
    expect(lyrics.lines.length, 1);
    expect(lyrics.lines.single.text, 'Привет мир');
    final words = lyrics.lines.single.words!;
    expect(words.map((w) => (w.from, w.to)).toList(), [(0, 3), (3, 6), (7, 10)]);
    expect(words.first.start.inMilliseconds, 1000);
    expect(words.last.end.inMilliseconds, 3000);
    expect(lyrics.indexAt(const Duration(milliseconds: 500)), -1);
  });
  test('Line-only and plain lyrics do not invent syllable timing', () {
    final lines = BetterLyrics.parse('<tt><body><p begin="00:01:02.300" end="00:01:05">Line</p></body></tt>')!;
    expect(lines.lines.single.at!.inMilliseconds, 62300);
    expect(lines.lines.single.words, isNull);
    expect(BetterLyrics.parse('<tt><body><p>Plain</p></body></tt>')!.synced, isFalse);
    expect(BetterLyrics.parse('<not-closed>'), isNull);
    expect(BetterLyrics.time('-1'), isNull);
    expect(BetterLyrics.time('1500ms')!.inMilliseconds, 1500);
  });
  test('Provider sends every cache-key field and accepts cached TTML without score', () async {
    final client = MockClient((r) async {
      expect(r.url.host, 'api.betterlyrics.org');
      expect(r.url.queryParameters, {'s': 'Example', 'a': 'Artist', 'al': 'Album', 'd': '154'});
      return http.Response(jsonEncode({'ttml': sample}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final result = await BetterLyrics(client).fetch(track, const Duration(milliseconds: 154999));
    expect(result?.lyrics.lines.single.text, 'Привет мир');
    client.close();
  });
  test('Cache miss 401 is distinct from missing lyrics and does not retry', () async {
    var calls = 0;
    final client = MockClient((r) async { calls++; return http.Response('{"error":"API key required"}', 401); });
    await expectLater(BetterLyrics(client).fetch(track, const Duration(seconds: 100)),
        throwsA(predicate((Object e) => e is BetterLyricsFailure && e.status == 401)));
    expect(calls, 1);
    client.close();
  });
  test('Rate limit pauses further API requests; low score is rejected', () async {
    var calls = 0;
    final client = MockClient((r) async { calls++; return http.Response('{}', 429, headers: {'retry-after': '60'}); });
    final api = BetterLyrics(client);
    await expectLater(api.fetch(track, Duration.zero), throwsA(isA<BetterLyricsFailure>()));
    await expectLater(api.fetch(track, Duration.zero), throwsA(isA<BetterLyricsFailure>()));
    expect(calls, 1);
    client.close();
    final lowScore = MockClient((r) async => http.Response(jsonEncode({'ttml': sample, 'score': 0.2}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    expect(await BetterLyrics(lowScore).fetch(track, Duration.zero), isNull);
    lowScore.close();
  });
  final livePath = Platform.environment['BETTER_LYRICS_LIVE_JSON'];
  test('Parse the live API probe without printing lyrics', () async {
    final data = jsonDecode(await File(livePath!).readAsString());
    final parsed = BetterLyrics.parse(data['ttml'] as String);
    expect(parsed, isNotNull);
    expect(parsed!.lines, isNotEmpty);
  }, skip: livePath == null || !File(livePath).existsSync());
}
