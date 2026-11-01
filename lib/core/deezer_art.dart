// Public Deezer catalog cover lookup; no ARL or account is needed for artwork.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'log.dart';

// Top-level isolate entry point: only image bytes are sent to the worker.
// An inline Isolate.run closure here accidentally captured the UI logger,
// Flutter's Element tree and a non-sendable CaveBinding, rejecting valid covers.
(int, int)? _decodeCoverDimensions(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    return (decoded.width, decoded.height);
  } catch (_) {
    return null;
  }
}

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
  static int _searchId = 0;

  static void _trace(String message, void Function(String)? onLog) {
    // Some Dart errors (notably unsendable-isolate errors) contain the entire
    // widget tree. Avoid rendering or synchronously writing megabyte-sized
    // exception strings on Flutter's UI isolate.
    final oneLine = message.replaceAll(RegExp(r'[\\r\\n]+'), ' ');
    final concise = oneLine.length > 500
        ? '${oneLine.substring(0, 500)}…'
        : oneLine;
    AppLog.info('DeezerArt: $concise');
    onLog?.call(concise);
  }

  static Future<Map<String, dynamic>?> _get(
      String path, String query, void Function(String)? onLog) async {
    final timer = Stopwatch()..start();
    _trace('API $path: запрос="$query", начало', onLog);
    try {
      final uri = Uri.https('api.deezer.com', path, {'q': query, 'limit': '20'});
      final response = await _client.get(uri).timeout(const Duration(seconds: 5));
      _trace('API $path: HTTP ${response.statusCode}, ${response.bodyBytes.length} байт, '
          '${timer.elapsedMilliseconds} мс', onLog);
      if (response.statusCode != 200 || response.bodyBytes.length > 500000) {
        _trace('API $path: ответ отклонён (HTTP или размер)', onLog);
        return null;
      }
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map) {
        _trace('API $path: получен неожиданный JSON', onLog);
        return null;
      }
      if (body['error'] != null) {
        final e = body['error'];
        _trace('API $path: ошибка Deezer код=${e is Map ? e['code'] : '?'} '
            'сообщение=${e is Map ? e['message'] : e}', onLog);
        return null;
      }
      _trace('API $path: записей ${body['data'] is List ? (body['data'] as List).length : 0}', onLog);
      return body.cast<String, dynamic>();
    } catch (e) {
      _trace('API $path: ${e.runtimeType} после ${timer.elapsedMilliseconds} мс ($e)', onLog);
      return null;
    }
  }

  static Future<DeezerArtwork?> find({
    required String artist,
    required String title,
    String album = '',
    void Function(String)? onLog,
  }) {
    final id = ++_searchId;
    final timer = Stopwatch()..start();
    void log(String message) =>
        _trace('#$id [${timer.elapsedMilliseconds} мс] $message', onLog);
    log('Начало: исполнитель="$artist", трек="$title", альбом="$album"');
    if (normalize(artist).isEmpty ||
        (normalize(title).isEmpty && normalize(album).isEmpty)) {
      log('Пустые параметры: поиск отменён');
      return Future.value(null);
    }
    final key = '${normalize(artist)}|${normalize(title)}|${normalize(album)}';
    final cached = _cache[key];
    if (cached != null && DateTime.now().isBefore(cached.$1)) {
      log('Кэш: ${cached.$2 == null ? 'ничего не найдено' : 'обложка найдена'}');
      return Future.value(cached.$2);
    }
    if (_inflight.containsKey(key)) log('Ожидаю предыдущий поиск того же трека');
    return _inflight[key] ??= _search(artist, title, album, log).then((result) {
      log(result == null
          ? 'Результат: обложка не найдена'
          : 'Результат: ${result.width}×${result.height}, ${result.bytes.length} байт');
      if (_cache.length >= 32) _cache.remove(_cache.keys.first);
      _cache[key] = (DateTime.now().add(Duration(minutes: result == null ? 1 : 30)), result);
      return result;
    }).whenComplete(() => _inflight.remove(key));
  }

  static Future<DeezerArtwork?> _search(
      String artist, String title, String album, void Function(String) log) async {
    // Race both metadata endpoints. An exact match from either can start the
    // image download immediately; do not wait for a slow unrelated endpoint.
    (String, String)? albumMatch(Map<String, dynamic>? data) {
      final candidates = data?['data'] as List? ?? const [];
      log('Альбомы: ${candidates.length} кандидатов');
      for (final item in candidates) {
        if (item is! Map) continue;
        final who = item['artist'];
        if (who is! Map || !same('${who['name'] ?? ''}', artist) ||
            !same('${item['title'] ?? ''}', album)) continue;
        final url = '${item['cover_xl'] ?? item['cover_big'] ?? ''}';
        log('Альбом: точное совпадение "${item['title']}", URL ${url.isEmpty ? 'пустой' : 'получен'}');
        return (url, '${item['title'] ?? album}');
      }
      if (candidates.isNotEmpty) {
        final first = candidates.first;
        log('Альбом: точного совпадения нет. Первый кандидат: '
            '"${first is Map ? first['title'] : '?'}"');
      }
      return null;
    }

    (String, String)? trackMatch(Map<String, dynamic>? data) {
      final candidates = data?['data'] as List? ?? const [];
      log('Треки: ${candidates.length} кандидатов');
      for (final item in candidates) {
        if (item is! Map) continue;
        final who = item['artist'];
        final release = item['album'];
        if (who is! Map || release is! Map) continue;
        if (!same('${who['name'] ?? ''}', artist) ||
            !same('${item['title_short'] ?? item['title'] ?? ''}', title)) continue;
        if (album.trim().isNotEmpty && !same('${release['title'] ?? ''}', album)) continue;
        final url = '${release['cover_xl'] ?? release['cover_big'] ?? ''}';
        log('Трек: точное совпадение "${item['title']}" в альбоме "${release['title']}", '
            'URL ${url.isEmpty ? 'пустой' : 'получен'}');
        return (url, '${release['title'] ?? album}');
      }
      if (candidates.isNotEmpty) {
        final first = candidates.first;
        final name = first is Map && first['artist'] is Map
            ? first['artist']['name'] : '?';
        final title = first is Map ? first['title'] : '?';
        log('Трек: совпадение отклонено. Первый кандидат: "$name" — "$title"');
      }
      return null;
    }

    final lookups = <Future<(String, String)?>>[
      if (album.trim().isNotEmpty)
        _get('/search/album', '$artist $album', log)
            .then(albumMatch),
      if (title.trim().isNotEmpty)
        _get('/search', '$artist $title', log)
            .then(trackMatch),
    ];
    if (lookups.isEmpty) return null;
    final first = await Future.any(lookups);
    // If the first request has no match, try all results without issuing any
    // additional HTTP requests. Prefer a valid non-empty artwork URL.
    final matches = first != null && first.$1.isNotEmpty
        ? <(String, String)>[first]
        : [for (final match in await Future.wait(lookups))
            if (match != null && match.$1.isNotEmpty) match];
    if (matches.isEmpty) {
      log('Итог: точных совпадений с обложкой нет');
      return null;
    }
    final (url, matchedAlbum) = matches.first;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' ||
        !(uri.host == 'dzcdn.net' || uri.host.endsWith('.dzcdn.net'))) {
      log('CDN: невалидный адрес обложки (требуется HTTPS *.dzcdn.net)');
      return null;
    }
    log('CDN: скачиваю обложку с ${uri.host}');
    final timer = Stopwatch()..start();
    try {
      final response = await _client.get(uri).timeout(const Duration(seconds: 7));
      log('CDN: HTTP ${response.statusCode}, ${response.bodyBytes.length} байт, '
          '${timer.elapsedMilliseconds} мс');
      if (response.statusCode != 200) {
        log('CDN: статус ответа не 200');
        return null;
      }
      if (response.bodyBytes.length > 8 * 1024 * 1024 ||
          response.bodyBytes.length < 1000) {
        log('CDN: отклонено из-за размера изображения');
        return null;
      }
      // Decoding 1200px+ images on the main isolate can freeze the UI.
      final bytes = response.bodyBytes;
      final size = await dimensionsInBackground(bytes)
          .timeout(const Duration(seconds: 5));
      if (size == null || size.$1 < 100 || size.$2 < 100) {
        log('CDN: картинка не распознана или слишком маленькая');
        return null;
      }
      log('CDN: изображение ${size.$1}×${size.$2} распознано за '
          '${timer.elapsedMilliseconds} мс');
      return DeezerArtwork(bytes, size.$1, size.$2, matchedAlbum);
    } catch (e) {
      log('CDN: ошибка ${e.runtimeType} после ${timer.elapsedMilliseconds} мс ($e)');
      return null;
    }
  }

  // Unlike Isolate.run(() => dimensions(bytes)), compute transfers a
  // top-level function and a single sendable Uint8List, not a closure that
  // may capture UI state from the lookup's logging callback.
  static Future<(int, int)?> dimensionsInBackground(Uint8List bytes) =>
      compute(_decodeCoverDimensions, bytes);

  static (int, int)? dimensions(Uint8List? bytes) =>
      bytes == null || bytes.isEmpty ? null : _decodeCoverDimensions(bytes);
}
