import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'lyrics.dart';
import 'models.dart';

class MusixmatchFailure implements Exception {
  final int status;
  final String stage, hint;
  const MusixmatchFailure(this.status, this.stage, [this.hint = '']);
  @override
  String toString() => 'Musixmatch: $stage, код $status${hint.isEmpty ? '' : ' ($hint)'}';
}

/// Token-based desktop protocol. No website scraping or HMAC signatures.
class Musixmatch {
  final http.Client client;
  final File? tokenFile;
  String? _token;
  DateTime? _tokenAt, _retryAfter;
  bool _loaded = false;
  Future<String>? _pendingToken;
  Musixmatch(this.client, {this.tokenFile});

  Future<Map?> _call(String endpoint, Map<String, String> query) async {
    final response = await client.get(Uri.https('apic-desktop.musixmatch.com', '/ws/1.1/$endpoint', {
      'app_id': 'web-desktop-app-v1.0', 'format': 'json', ...query,
    }), headers: {
      'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      'Cookie': 'x-mxm-token-guid=',
    }).timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) throw MusixmatchFailure(response.statusCode, endpoint);
    final text = utf8.decode(response.bodyBytes).trimLeft();
    if (text.startsWith('<')) throw MusixmatchFailure(0, endpoint, 'сервер или сетевой фильтр вернул HTML вместо JSON');
    dynamic json;
    try { json = jsonDecode(text); } catch (_) { throw MusixmatchFailure(0, endpoint, 'некорректный JSON'); }
    final message = json is Map ? json['message'] : null;
    final header = message is Map ? message['header'] : null;
    if (header is! Map || header['status_code'] is! num) throw MusixmatchFailure(0, endpoint, 'нет статуса API');
    final status = (header['status_code'] as num).toInt();
    if (status == 404) return null;
    // Do not echo remote bodies, URLs or tokens into the UI/log.
    if (status != 200) throw MusixmatchFailure(status, endpoint, header['hint'] == 'captcha' ? 'captcha' : '');
    final body = message['body'];
    return body is Map ? body : null;
  }

  Future<String> _getToken() => _pendingToken ??= _loadToken().whenComplete(() => _pendingToken = null);

  Future<String> _loadToken() async {
    final now = DateTime.now();
    if (!_loaded) {
      _loaded = true;
      try {
        final j = jsonDecode(await tokenFile!.readAsString());
        if (j is Map && j['token'] is String) {
          _token = j['token'] as String;
          _tokenAt = DateTime.tryParse('${j['at']}');
        }
      } catch (_) {}
    }
    if (_token != null && _token!.isNotEmpty && !_token!.startsWith('UpgradeOnly') &&
        _tokenAt != null && !now.isBefore(_tokenAt!) && now.difference(_tokenAt!) < const Duration(hours: 6)) return _token!;
    if (_retryAfter != null && now.isBefore(_retryAfter!)) throw const MusixmatchFailure(429, 'token.get', 'повторите позже');
    try {
      final body = await _call('token.get', {'t': '${now.millisecondsSinceEpoch}'});
      final token = body?['user_token'];
      if (token is! String || token.isEmpty || token.startsWith('UpgradeOnly')) {
        throw const MusixmatchFailure(0, 'token.get', 'полноценный токен не получен');
      }
      _token = token;
      _tokenAt = now;
      try { await tokenFile?.writeAsString(jsonEncode({'token': token, 'at': now.toIso8601String()})); } catch (_) {}
      return token;
    } catch (_) {
      _retryAfter = now.add(const Duration(minutes: 1));
      rethrow;
    }
  }

  Future<Map?> _authenticated(String endpoint, Map<String, String> query) async {
    final token = await _getToken();
    try {
      return await _call(endpoint, {...query, 'usertoken': token});
    } on MusixmatchFailure catch (e) {
      if (e.status != 401 || e.hint == 'captcha') rethrow;
      if (_token == token) { _token = null; _tokenAt = null; }
      final fresh = await _getToken();
      return _call(endpoint, {...query, 'usertoken': fresh}); // exactly one refresh
    }
  }

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  Future<Lyrics?> find(Track track, Duration duration) async {
    final body = await _authenticated('matcher.track.get', {
      'q_track': track.title, 'q_artist': track.displayArtist, 'q_album': track.album,
      if (duration > Duration.zero) 'q_duration': '${duration.inSeconds}',
    });
    final found = body?['track'];
    if (found is! Map || _norm('${found['track_name']}') != _norm(track.title) ||
        _norm('${found['artist_name']}') != _norm(track.displayArtist)) return null;
    final length = found['track_length'];
    if (duration > Duration.zero && length is num && (length - duration.inMilliseconds / 1000).abs() > 3) return null;
    final id = found['commontrack_id'];
    if (id == null) return null;
    final rich = await _authenticated('track.richsync.get', {'commontrack_id': '$id'});
    final payload = rich?['richsync'];
    if (payload is Map && payload['richsync_body'] is String) {
      try {
        final parsed = parse(jsonDecode(payload['richsync_body'] as String));
        if (parsed != null) return parsed;
      } on FormatException { /* line fallback below */ }
    }
    final sub = await _authenticated('track.subtitle.get', {'commontrack_id': '$id', 'subtitle_format': 'lrc'});
    final list = sub?['subtitle_list'];
    if (list is List) {
      for (final item in list) {
        final subtitle = item is Map ? item['subtitle'] : null;
        if (subtitle is Map && subtitle['subtitle_body'] is String) {
          final parsed = Lyrics.fromLrclib({'syncedLyrics': subtitle['subtitle_body']});
          if (parsed != null) return parsed.copyWith(origin: 'musixmatch');
        }
      }
    }
    return null;
  }

  static Lyrics? parse(dynamic data) {
    if (data is! List) return null;
    final lines = <LyricLine>[];
    for (var rowIndex = 0; rowIndex < data.length; rowIndex++) {
      final row = data[rowIndex];
      if (row is! Map || row['ts'] is! num || row['l'] is! List) continue;
      final start = (row['ts'] as num).toDouble();
      final segments = row['l'] as List;
      if (segments.isEmpty || !start.isFinite || start < 0) continue;
      final nextRow = rowIndex + 1 < data.length ? data[rowIndex + 1] : null;
      final last = segments.last;
      final lastOffset = last is Map && last['o'] is num ? (last['o'] as num).toDouble() : 0.0;
      // Some payloads omit te: only the final segment's end then needs an estimate.
      final end = row['te'] is num ? (row['te'] as num).toDouble()
          : nextRow is Map && nextRow['ts'] is num ? (nextRow['ts'] as num).toDouble() : start + lastOffset + 0.6;
      if (!end.isFinite || end <= start) continue;
      final canonical = row['x'] is String ? row['x'] as String : null;
      final text = StringBuffer();
      final words = <KWord>[];
      var cursor = 0;
      for (var i = 0; i < segments.length; i++) {
        final s = segments[i];
        if (s is! Map || s['c'] is! String || s['o'] is! num) return null;
        final chunk = s['c'] as String;
        final offset = (s['o'] as num).toDouble();
        final next = i + 1 < segments.length ? segments[i + 1] : null;
        final finish = next is Map && next['o'] is num ? start + (next['o'] as num).toDouble() : end;
        if (!offset.isFinite || !finish.isFinite || offset < 0 || start + offset > end || finish < start + offset) return null;
        int from, to;
        if (canonical != null) {
          from = canonical.indexOf(chunk, cursor);
          if (from < 0) return null;
          to = from + chunk.length;
          cursor = to;
        } else {
          from = text.length;
          text.write(chunk);
          to = text.length;
        }
        if (to > from) words.add(KWord(from, to, Duration(milliseconds: ((start + offset) * 1000).round()),
            Duration(milliseconds: (finish.clamp(start + offset, end) * 1000).round())));
      }
      final line = canonical ?? text.toString();
      if (line.isNotEmpty && words.isNotEmpty) lines.add(LyricLine(Duration(milliseconds: (start * 1000).round()), line, words));
    }
    lines.sort((a, b) => a.at!.compareTo(b.at!));
    return lines.isEmpty ? null : Lyrics(lines, synced: true, origin: 'musixmatch');
  }
}
