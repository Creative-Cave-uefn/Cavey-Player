import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'lyrics.dart';
import 'models.dart';

/// Web API adapter following Strvm/musicxmatch-api. No bundled credentials.
/// The web protocol can change; callers must retain their fallback provider.
class Musixmatch {
  final http.Client client;
  String? _secret;
  Musixmatch(this.client);

  Future<String> _get(Uri uri) async {
    final r = await client.get(uri, headers: {
      'User-Agent': 'Mozilla/5.0',
      'Cookie': 'mxm_bab=AB',
    }).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) throw Exception('Musixmatch: HTTP ${r.statusCode}');
    return utf8.decode(r.bodyBytes);
  }

  Future<String> _key() async {
    if (_secret != null) return _secret!;
    final html = await _get(Uri.https('www.musixmatch.com', '/search'));
    final script = RegExp(r'src="([^"]*/_next/static/chunks/pages/_app-[^"]+\.js)"').firstMatch(html)?.group(1);
    if (script == null) throw Exception('Musixmatch: web protocol changed');
    final js = await _get(Uri.https('www.musixmatch.com', '/').resolve(script));
    final encoded = RegExp(r'from\(\s*"(.*?)"\s*\.split').firstMatch(js)?.group(1);
    if (encoded == null) throw Exception('Musixmatch: signing key unavailable');
    return _secret = utf8.decode(base64.decode(encoded.split('').reversed.join()));
  }

  Future<Map?> _request(String endpoint, Map<String, String> query) async {
    final secret = await _key();
    final url = Uri.https('www.musixmatch.com', '/ws/1.1/$endpoint', {
      'app_id': 'web-desktop-app-v1.0', 'format': 'json', ...query,
    }).toString();
    final now = DateTime.now();
    final date = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final signature = base64.encode(Hmac(sha256, utf8.encode(secret)).convert(utf8.encode('$url$date')).bytes);
    final data = jsonDecode(await _get(Uri.parse('$url&signature=${Uri.encodeComponent(signature)}&signature_protocol=sha256')));
    final message = data is Map ? data['message'] : null;
    if (message is! Map) return null;
    final header = message['header'];
    if (header is! Map) throw Exception('Musixmatch: некорректный ответ API');
    if (header['status_code'] == 404) return null;
    if (header['status_code'] != 200) throw Exception('Musixmatch: API ${header['status_code']}');
    final body = message['body'];
    return body is Map ? body : null;
  }

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  Future<Lyrics?> find(Track track, Duration duration) async {
    final body = await _request('track.search', {'q': '${track.displayArtist} ${track.title}', 'f_has_lyrics': 'true', 'page_size': '20', 'page': '1'});
    final list = body?['track_list'];
    if (list is! List) return null;
    for (final item in list) {
      final t = item is Map ? item['track'] : null;
      if (t is! Map || t['track_id'] == null) continue;
      if (_norm('${t['track_name']}') != _norm(track.title) || _norm('${t['artist_name']}') != _norm(track.displayArtist)) continue;
      final length = t['track_length'];
      if (duration > Duration.zero && length is num && (length - duration.inMilliseconds / 1000).abs() > 3) continue;
      final rich = await _request('track.richsync.get', {'track_id': '${t['track_id']}'});
      final payload = rich?['richsync'];
      if (payload is Map && payload['richsync_body'] is String) {
        final lyrics = parse(jsonDecode(payload['richsync_body'] as String));
        if (lyrics != null) return lyrics;
      }
    }
    return null;
  }

  /// ts/te are absolute seconds; segment offsets are relative to the line.
  static Lyrics? parse(dynamic data) {
    if (data is! List) return null;
    final lines = <LyricLine>[];
    for (final row in data) {
      if (row is! Map || row['ts'] is! num || row['te'] is! num || row['l'] is! List) continue;
      final start = (row['ts'] as num).toDouble(), end = (row['te'] as num).toDouble();
      if (!start.isFinite || !end.isFinite || start < 0 || end <= start) continue;
      final segments = row['l'] as List;
      final text = StringBuffer();
      final words = <KWord>[];
      for (var i = 0; i < segments.length; i++) {
        final s = segments[i];
        if (s is! Map || s['c'] is! String || s['o'] is! num) continue;
        final offset = (s['o'] as num).toDouble();
        final next = i + 1 < segments.length ? segments[i + 1] : null;
        final finish = next is Map && next['o'] is num ? start + (next['o'] as num).toDouble() : end;
        if (!offset.isFinite || !finish.isFinite || offset < 0 || start + offset > end || finish < start + offset) return null;
        final from = text.length;
        text.write(s['c']);
        if (text.length > from) words.add(KWord(from, text.length,
            Duration(milliseconds: ((start + offset) * 1000).round()),
            Duration(milliseconds: (finish.clamp(start + offset, end) * 1000).round())));
      }
      if (text.isNotEmpty && words.isNotEmpty) lines.add(LyricLine(Duration(milliseconds: (start * 1000).round()), text.toString(), words));
    }
    lines.sort((a, b) => a.at!.compareTo(b.at!));
    return lines.isEmpty ? null : Lyrics(lines, synced: true, origin: 'musixmatch');
  }
}

