import 'package:cave_player/core/dl/zotify.dart';
import 'package:cave_player/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Only Spotify track, album and playlist URLs are routed to Zotify', () {
    expect(Zotify.accepts('https://open.spotify.com/track/abc123?si=hello'), isTrue);
    expect(Zotify.accepts('https://open.spotify.com/intl-ru/album/abc123'), isTrue);
    expect(Zotify.accepts('spotify:playlist:abc123'), isTrue);
    expect(Zotify.accepts('https://open.spotify.com.evil.test/track/abc123'), isFalse);
    expect(Zotify.accepts('https://youtube.com/watch?v=x'), isFalse);
    expect(Zotify.accepts('Artist - Song'), isFalse);
    expect(Zotify.accepts('spotify:artist:abc123'), isFalse);
  });
  test('Existing installations retain the standard downloader; preference survives restart', () {
    expect(Settings.fromJson({}).useZotify, isFalse);
    final settings = Settings()..useZotify = true..zotifyExecutable = r'C:\Music Tools\zotify.exe';
    final restored = Settings.fromJson(settings.toJson());
    expect(restored.useZotify, isTrue);
    expect(restored.zotifyExecutable, settings.zotifyExecutable);
  });
}
