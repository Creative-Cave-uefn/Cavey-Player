import 'package:cave_player/mobile/mobile_youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Mobile YouTube URL allowlist', () {
    for (final url in [
      'https://www.youtube.com/watch?v=abc123',
      'https://youtube.com/watch?v=abc123&t=10',
      'https://m.youtube.com/watch?v=abc123',
      'https://music.youtube.com/watch?v=abc123',
      'https://youtu.be/abc123',
      'https://www.youtube.com/shorts/abc123',
      'https://www.youtube.com/live/abc123',
    ]) {
      test('accepts $url', () {
        expect(MobileYoutubeService.isYoutubeUrl(url), isTrue);
      });
    }

    for (final url in [
      '',
      'https://www.youtube.com/watch',
      'https://www.youtube.com/playlist?list=abc',
      'https://youtu.be/',
      'http://www.youtube.com/watch?v=abc123',
      'https://youtube.com.evil.test/watch?v=abc123',
      'https://evil.test/youtube.com/watch?v=abc123',
      'https://user:password@youtube.com/watch?v=abc123',
      'file:///sdcard/music.mp3',
      'https://www.google.com/',
    ]) {
      test('rejects $url', () {
        expect(MobileYoutubeService.isYoutubeUrl(url), isFalse);
      });
    }
  });
}
