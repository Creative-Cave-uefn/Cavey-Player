// Public Deezer catalog cover lookup; no ARL or account is needed for artwork.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

class DeezerArtwork {
  final Uint8List bytes;
  final int width;
  final int height;
  final String album;
  const DeezerArtwork(this.bytes, this.width, this.height, this.album);

  int get pixelCount => width * height;
  bool betterThan(int width, int height) =>
      this.width >= width && this.height >= height && pixelCount > width * height;
}

class DeezerArt {
  static String normalize(String text) => text.toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

  static bool same(String a, String b) =>
      normalize(a).isNotEmpty && normalize(a) == normalize(b);

  // Reuse HTTP connections and avoid looking up the same album on every edit.
  static final http.Client _client = http.Client();
  static final Map<String, (DateTime, DeezerArtwork?)> _cache = {};
  static final Map<String, Future<DeezerArtwork?>> _inflight = {};

  static Future<Map<String, dynamic>?> _get(String path, String query) async {
    final uri = Uri.https('api.deezer.com', path, {'q': query, 'limit': '20'});
    final response = await _client.get(uri).timeout(const Duration(seconds: 6));
    if (response.statusCode != 200 || response.bodyBytes.length > 500000) return null;
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map || body['error'] != null) return null;
    return body.cast<String, dynamic>();
  }

  static Future<DeezerArtwork?> find({
    required String artist,
    required String title,
    String album = '',
  }) {
    if (normalize(artist).isEmpty ||
        (normalize(title).isEmpty && normalize(album).isEmpty)) {
      return Future.value(null);
    }
    final key = '${normalize(artist)}|${normalize(title)}|${normalize(album)}';
    final cached = _cache[key];
    if (cached != null && DateTime.now().isBefore(cached.$1)) {
      return Future.value(cached.$2);
    }
    return _inflight[key] ??= _search(artist, title, album).then((result) {
      if (_cache.length >= 32) _cache.remove(_cache.keys.first);
      _cache[key] = (DateTime.now().add(Duration(minutes: result == null ? 1 : 30)), result);
      return result;
    }).whenComplete(() => _inflight.remove(key));
  }

  static Future<DeezerArtwork?> _search(String artist, String title, String album) async {
    // Start both catalog requests together, but still prefer an exact album
    // when it exists. A slow album lookup no longer serializes the track lookup.
    final albumSearch = album.trim().isEmpty
        ? Future<Map<String, dynamic>?>.value(null)
        : _get('/search/album', '$artist $album').catchError((Object _) => null);
    final trackSearch = title.trim().isEmpty
        ? Future<Map<String, dynamic>?>.value(null)
        : _get('/search', '$artist $title').catchError((Object _) => null);
    final results = await Future.wait([albumSearch, trackSearch]);
    String? url;
    var matchedAlbum = album;
    for (final item in (results[0]?['data'] as List? ?? const [])) {
      if (item is! Map) continue;
      final who = item['artist'];
      if (who is! Map || !same('${who['name'] ?? ''}', artist) ||
          !same('${item['title'] ?? ''}', album)) continue;
      url = '${item['cover_xl'] ?? item['cover_big'] ?? ''}';
      matchedAlbum = '${item['title'] ?? album}';
      break;
    }
    if (url == null || url.isEmpty) {
      for (final item in (results[1]?['data'] as List? ?? const [])) {
        if (item is! Map) continue;
        final who = item['artist'];
        final release = item['album'];
        if (who is! Map || release is! Map) continue;
        if (!same('${who['name'] ?? ''}', artist) ||
            !same('${item['title_short'] ?? item['title'] ?? ''}', title)) continue;
        if (album.trim().isNotEmpty && !same('${release['title'] ?? ''}', album)) continue;
        url = '${release['cover_xl'] ?? release['cover_big'] ?? ''}';
        matchedAlbum = '${release['title'] ?? album}';
        break;
      }
    }
    if (url == null || url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' ||
        !(uri.host == 'dzcdn.net' || uri.host.endsWith('.dzcdn.net'))) return null;
    try {
      final response = await _client.get(uri).timeout(const Duration(seconds: 9));
      if (response.statusCode != 200 || response.bodyBytes.length > 8 * 1024 * 1024 ||
          response.bodyBytes.length < 1000) return null;
      final decoded = img.decodeImage(response.bodyBytes);
      if (decoded == null || decoded.width < 100 || decoded.height < 100) return null;
      return DeezerArtwork(response.bodyBytes, decoded.width, decoded.height, matchedAlbum);
    } on TimeoutException {
      return null;
    }
  }

  static (int, int)? dimensions(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final data = img.decodeImage(bytes);
      if (data == null) return null;
      return (data.width, data.height);
    } catch (_) {
      return null;
    }
  }
}
