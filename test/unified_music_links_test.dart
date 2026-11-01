import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/dl/music_links.dart';
import 'package:cave_player/core/dl/text.dart';
import 'package:cave_player/core/dl/tools.dart';
import 'package:cave_player/core/dl/youtube.dart';

void main() {
  group('Universal music link router', () {
    test('recognizes catalog links for metadata search', () {
      expect(MusicLink.parse('https://open.spotify.com/track/abc123').source, MusicSource.spotify);
      expect(MusicLink.parse('spotify:track:abc123').source, MusicSource.spotify);
      expect(MusicLink.parse('https://www.deezer.com/album/12').isCatalog, isTrue);
      expect(MusicLink.parse('https://music.apple.com/us/album/example/123').isCatalog, isTrue);
      expect(MusicLink.parse('https://music.yandex.ru/album/123').isCatalog, isTrue);
    });
    test('routes public audio links directly', () {
      for (final link in [
        'https://youtu.be/abcdefghijk',
        'https://soundcloud.com/artist/track',
        'https://on.soundcloud.com/a1b2c3',
        'https://artist.bandcamp.com/track/song',
        'https://audiomack.com/artist/song/test',
        'https://www.mixcloud.com/artist/show/',
        'https://archive.org/details/sound-recording',
      ]) {
        expect(MusicLink.parse(link).isDirectAudio, isTrue, reason: link);
      }
      expect(MusicLink.parse('https://soundcloud.com/artist/sets/album').isCollection, isTrue);
      expect(MusicLink.parse('https://www.youtube.com/playlist?list=PLtest').isCollection, isTrue);
    });
    test('does not use arbitrary URLs as downloads or catalogs', () {
      for (final value in [
        'file:///C:/secrets.txt',
        'http://localhost:8080/admin',
        'https://127.0.0.1/private',
        'https://open.spotify.com.evil.example/track/test',
        'https://user@example.com/song',
        'https://example.org/track/123',
        'javascript:alert(1)',
      ]) {
        expect(MusicLink.parse(value).isSupported, isFalse, reason: value);
      }
      expect(MusicLink.parse('Artist - Song').source, MusicSource.text);
    });
  });

  test('YouTube search variants and transient errors', () {
    final meta = TrackMeta(artist: 'Artist', title: 'Song');
    final queries = YouTube.searchQueries(meta);
    expect(queries, contains('Artist Song official audio'));
    expect(queries, contains('Artist Song topic'));
    expect(queries, contains('Artist Song lyrics'));
    expect(YouTube.retryable('HTTP Error 429: Too Many Requests'), isTrue);
    expect(YouTube.retryable('connection reset'), isTrue);
    expect(YouTube.retryable('Video is unavailable'), isFalse);
    expect(YouTube.maxConcurrentSearches, 2);
  });

  test('Deno config enables EJS challenge components', () async {
    final temp = await Directory.systemTemp.createTemp('cave-ejs-');
    try {
      final tools = Tools(temp);
      expect(tools.jsArgs, isEmpty);
      await tools.deno.writeAsString('');
      expect(tools.jsArgs, contains('ejs:npm'));
      expect(tools.jsArgs, contains('--remote-components'));
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
