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
    final response = await _client.get(uri).timeout(const Duration(seconds: 5));
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
    // Race both metadata endpoints. An exact match from either can start the
    // image download immediately; do not wait for a slow unrelated endpoint.
    (String, String)? albumMatch(Map<String, dynamic>? data) {
      for (final item in (data?['data'] as List? ?? const [])) {
        if (item is! Map) continue;
        final who = item['artist'];
        if (who is! Map || !same('${who['name'] ?? ''}', artist) ||
            !same('${item['title'] ?? ''}', album)) continue;
        return ('${item['cover_xl'] ?? item['cover_big'] ?? ''}',
            '${item['title'] ?? album}');
      }
      return null;
    }

    (String, String)? trackMatch(Map<String, dynamic>? data) {
      for (final item in (data?['data'] as List? ?? const [])) {
        if (item is! Map) continue;
        final who = item['artist'];
        final release = item['album'];
        if (who is! Map || release is! Map) continue;
        if (!same('${who['name'] ?? ''}', artist) ||
            !same('${item['title_short'] ?? item['title'] ?? ''}', title)) continue;
        if (album.trim().isNotEmpty && !same('${release['title'] ?? ''}', album)) continue;
        return ('${release['cover_xl'] ?? release['cover_big'] ?? ''}',
            '${release['title'] ?? album}');
      }
      return null;
    }

    final lookups = <Future<(String, String)?>>[
      if (album.trim().isNotEmpty)
        _get('/search/album', '$artist $album')
            .then(albumMatch).catchError((Object _) => null),
      if (title.trim().isNotEmpty)
        _get('/search', '$artist $title')
            .then(trackMatch).catchError((Object _) => null),
    ];
    if (lookups.isEmpty) return null;
    final first = await Future.any(lookups);
    // If the first request has no match, try all results without issuing any
    // additional HTTP requests. Prefer a valid non-empty artwork URL.
    final matches = first != null && first.$1.isNotEmpty
        ? <(String, String)>[first]
        : [for (final match in await Future.wait(lookups))
            if (match != null && match.$1.isNotEmpty) match];
    if (matches.isEmpty) return null;
    final (url, matchedAlbum) = matches.first;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' ||
        !(uri.host == 'dzcdn.net' || uri.host.endsWith('.dzcdn.net'))) return null;
    try {
      final response = await _client.get(uri).timeout(const Duration(seconds: 7));
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
