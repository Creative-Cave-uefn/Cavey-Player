import 'package:cave_player/core/dl/deezer.dart';
import 'package:cave_player/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Deezer only accepts strict title search or its own media URLs', () {
    for (final input in [
      'Artist - Song', 'Артист — Песня', 'A - B',
      'https://www.deezer.com/en/track/1234',
      'https://deezer.com/track/1234',
      'https://deezer.com/album/567',
      'https://www.deezer.com/playlist/789',
    ]) {
      expect(DeezerMusic.accepts(input), isTrue, reason: input);
    }
    for (final input in [
      '', 'Song', 'https://deezer.com/', 'https://deezer.com/track/foo',
      'https://deezer.com.evil.example/track/123',
      'https://vk.com/audio123_456', 'https://soundcloud.com/user/song',
      'ftp://deezer.com/track/12',
    ]) {
      expect(DeezerMusic.accepts(input), isFalse, reason: input);
    }
  });

  test('Deezer persists and replaces old VK setting', () {
    for (final name in ['youtube', 'sockseek', 'bandcamp', 'deezer']) {
      final settings = Settings()..downloadProvider = name;
      expect(Settings.fromJson(settings.toJson()).downloadProvider, name);
    }
    expect(Settings.fromJson({'downloadProvider': 'vk'}).downloadProvider, 'deezer');
    expect(Settings.fromJson({'downloadProvider': 'zotify'}).downloadProvider, 'youtube');
    expect(Settings.fromJson({'downloadProvider': 'soundcloud'}).downloadProvider, 'youtube');
  });
}
