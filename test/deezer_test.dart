import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/dl/deezer.dart';

void main() {
  group('Deezer input validation', () {
    test('artist-title query', () {
      expect(DeezerMusic.accepts('Artist - Song'), isTrue);
      expect(DeezerMusic.accepts('Artist — Song'), isTrue);
      expect(DeezerMusic.accepts('Song'), isFalse);
      expect(DeezerMusic.accepts(''), isFalse);
    });
    test('track, album, playlist URLs', () {
      expect(DeezerMusic.accepts('https://www.deezer.com/track/123'), isTrue);
      expect(DeezerMusic.accepts('https://deezer.com/en/album/123'), isTrue);
      expect(DeezerMusic.accepts('https://www.deezer.com/playlist/123'), isTrue);
    });
    test('reject other hosts and unexpected paths', () {
      expect(DeezerMusic.accepts('https://deezer.com.attacker.invalid/track/123'), isFalse);
      expect(DeezerMusic.accepts('https://example.com/track/123'), isFalse);
      expect(DeezerMusic.accepts('https://www.deezer.com/user/123'), isFalse);
      expect(DeezerMusic.accepts('https://user@www.deezer.com/track/123'), isFalse);
    });
  });
}
