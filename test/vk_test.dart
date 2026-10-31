import 'package:cave_player/core/dl/vk.dart';
import 'package:cave_player/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('VK accepts exact text search and supported VK media URLs only', () {
    for (final input in [
      'Artist - Song', 'Артист — Песня',
      'https://vk.com/audio-123_456',
      'https://m.vk.com/audio123_456?from=music',
      'https://vk.com/music/playlist/-123_456_key',
      'https://vk.ru/music/playlist/123_456',
    ]) { expect(VkMusic.accepts(input), isTrue, reason: input); }
    for (final input in [
      '', 'Song', 'https://vk.com/',
      'https://vk.com/id1',
      'https://vk.com/music/playlist/nope',
      'https://vk.com.evil.example/audio-123_456',
      'https://soundcloud.com/test/song',
      'ftp://vk.com/audio123_456',
    ]) { expect(VkMusic.accepts(input), isFalse, reason: input); }
  });

  test('VK source survives Settings JSON round-trip; previous providers unchanged', () {
    for (final name in ['youtube', 'sockseek', 'bandcamp', 'vk']) {
      final s = Settings()..downloadProvider = name;
      expect(Settings.fromJson(s.toJson()).downloadProvider, name);
    }
    expect(Settings.fromJson({'downloadProvider': 'zotify'}).downloadProvider, 'youtube');
    expect(Settings.fromJson({'downloadProvider': 'soundcloud'}).downloadProvider, 'youtube');
  });
}
