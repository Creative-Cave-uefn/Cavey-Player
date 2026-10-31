import 'package:cave_player/core/dl/bandcamp.dart';
import 'package:cave_player/core/dl/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Bandcamp only accepts direct track and album URLs', () {
    expect(Bandcamp.accepts('https://artist.bandcamp.com/track/song'), isTrue);
    expect(Bandcamp.accepts('https://artist.bandcamp.com/album/record?a=1'), isTrue);
    expect(Bandcamp.isAlbum('https://artist.bandcamp.com/album/record'), isTrue);
    expect(Bandcamp.isAlbum('https://artist.bandcamp.com/track/song'), isFalse);
    for (final input in [
      'Artist - Song',
      'https://bandcamp.com/search?q=song',
      'https://artist.bandcamp.com/',
      'https://artist.bandcamp.com/music',
      'https://artist.bandcamp.com/track/',
      'https://bandcamp.com.evil.test/track/song',
      'https://soundcloud.com/artist/track',
      'https://youtube.com/watch?v=dQw4w9WgXcQ',
      'ftp://artist.bandcamp.com/track/song',
    ]) { expect(Bandcamp.accepts(input), isFalse, reason: input); }
  });

  test('YouTube mode does not accept third-party audio links', () {
    expect(Bandcamp.youtubeUrl('https://www.youtube.com/watch?v=123'), isTrue);
    expect(Bandcamp.youtubeUrl('https://youtu.be/id'), isTrue);
    expect(Bandcamp.youtubeUrl('https://music.youtube.com/watch?v=123'), isTrue);
    expect(Bandcamp.youtubeUrl('https://soundcloud.com/artist/track'), isFalse);
    expect(Bandcamp.youtubeUrl('https://youtube.com.evil.com/watch?v=123'), isFalse);
  });

  test('YouTube candidates cannot route to SoundCloud', () {
    final candidate = Candidate('12345678901', 'Track', 'Artist', 200);
    expect(candidate.url, 'https://www.youtube.com/watch?v=12345678901');
    expect(candidate.site, 'YouTube');
  });
}
