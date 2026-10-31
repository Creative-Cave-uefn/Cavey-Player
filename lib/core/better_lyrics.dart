import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'lyrics.dart';
import 'models.dart';

class BetterLyricsFailure implements Exception {
  final int status;
  final String message;
  BetterLyricsFailure(this.status, this.message);
  @override
  String toString() => 'Better Lyrics: $message${status == 0 ? '' : ' (HTTP $status)'}';
}

class BetterLyricsResult {
  final String ttml;
  final Lyrics lyrics;
  BetterLyricsResult(this.ttml, this.lyrics);
}

/// Public cache-first API documented at docs.betterlyrics.org.
class BetterLyrics {
  final http.Client client;
  DateTime? _retryAfter;
  BetterLyrics(this.client);

  Future<BetterLyricsResult?> fetch(Track track, Duration duration, {void Function(String)? onDiagnostic}) async {
    if (_retryAfter != null && DateTime.now().isBefore(_retryAfter!)) {
      throw BetterLyricsFailure(429, 'пауза после ограничения запросов, повторите позже');
    }
    final query = {'s': track.title.trim(), 'a': track.displayArtist.trim(), 'al': track.album.trim(), 'd': '${duration.inSeconds}'};
    onDiagnostic?.call('Запрос: ${query['a']} — ${query['s']}; альбом: ${query['al']}; длительность: ${query['d']} с');
    final response = await client.get(Uri.https('api.betterlyrics.org', '/getLyrics', query),
        headers: {'Accept': 'application/json', 'User-Agent': 'CavePlayer'})
        .timeout(const Duration(seconds: 10));
    onDiagnostic?.call('HTTP ${response.statusCode}; кэш: ${response.headers['x-cache-status'] ?? 'не указан'}');
    if (response.statusCode == 401) {
      throw BetterLyricsFailure(401, 'публичный кэш не обслужил запрос: для незакэшированной песни API требует ключ. Проверьте альбом и длительность; используется резервный источник');
    }
    if (response.statusCode == 404 || response.headers['x-cache-status'] == 'NEGATIVE_HIT') return null;
    if (response.statusCode == 429) {
      final delay = int.tryParse(response.headers['retry-after'] ?? '') ?? 60;
      _retryAfter = DateTime.now().add(Duration(seconds: delay > 0 ? delay : 60));
      throw BetterLyricsFailure(429, 'ограничение запросов, повторите позже');
    }
    if (response.statusCode != 200) throw BetterLyricsFailure(response.statusCode, 'сервис недоступен');
    dynamic data;
    try { data = jsonDecode(utf8.decode(response.bodyBytes)); }
    catch (_) { throw BetterLyricsFailure(0, 'получен ответ не в формате JSON'); }
    if (data is! Map) throw BetterLyricsFailure(0, 'некорректная структура ответа');
    final score = data['score'];
    if (score is num && (!score.isFinite || score < 0.8)) {
      onDiagnostic?.call('Результат отклонён: низкая уверенность совпадения ($score).');
      return null;
    }
    final ttml = data['ttml'];
    if (ttml is! String || ttml.trim().isEmpty) return null;
    final lyrics = parse(ttml);
    if (lyrics == null) throw BetterLyricsFailure(0, 'TTML получен, но текст или тайминги не распознаны');
    onDiagnostic?.call('TTML получен: ${lyrics.lines.length} строк, ${lyrics.lines.fold<int>(0, (n, l) => n + (l.words?.length ?? 0))} сегментов с таймингами.');
    return BetterLyricsResult(ttml, lyrics);
  }

  static Duration? time(String? value) {
    if (value == null) return null;
    final raw = value.trim();
    final offset = RegExp(r'^(\d+(?:\.\d+)?)(ms|s)$').firstMatch(raw);
    if (offset != null) {
      final number = double.tryParse(offset[1]!);
      if (number == null || !number.isFinite) return null;
      return Duration(milliseconds: (number * (offset[2] == 'ms' ? 1 : 1000)).round());
    }
    final parts = raw.split(':');
    if (parts.isEmpty || parts.length > 3) return null;
    var seconds = 0.0;
    for (final part in parts) {
      final number = double.tryParse(part);
      if (number == null || !number.isFinite || number < 0) return null;
      seconds = seconds * 60 + number;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }

  static Lyrics? parse(String raw) {
    if (raw.length > 2 * 1024 * 1024) return null;
    XmlDocument doc;
    try { doc = XmlDocument.parse(raw); } catch (_) { return null; }
    final bodies = doc.descendants.whereType<XmlElement>().where((e) => e.name.local == 'body');
    if (bodies.isEmpty) return null;
    final lines = <LyricLine>[];
    for (final p in bodies.first.descendants.whereType<XmlElement>().where((e) => e.name.local == 'p')) {
      final lineStart = time(p.getAttribute('begin'));
      final lineEnd = time(p.getAttribute('end'));
      final text = StringBuffer();
      final words = <KWord>[];
      void append(String value, Duration? start, Duration? end, bool timed) {
        final from = text.length;
        text.write(value);
        if (timed && start != null && end != null && end > start && value.isNotEmpty) {
          words.add(KWord(from, text.length, start, end));
        }
      }
      void visit(XmlNode node, Duration? start, Duration? end, bool timed) {
        if (node is XmlText) { append(node.value, start, end, timed); return; }
        if (node is XmlCDATA) { append(node.value, start, end, timed); return; }
        if (node is! XmlElement) return;
        if (node.name.local == 'br') { append('\n', null, null, false); return; }
        final a = time(node.getAttribute('begin')) ?? start;
        final b = time(node.getAttribute('end')) ?? end;
        final ownTiming = node.name.local == 'span' && node.getAttribute('begin') != null && a != null && b != null;
        for (final child in node.children) { visit(child, a, b, timed || ownTiming); }
      }
      for (final child in p.children) { visit(child, lineStart, lineEnd, false); }
      final full = text.toString();
      final leading = full.length - full.trimLeft().length;
      final trimmed = full.trim();
      if (trimmed.isEmpty) continue;
      final adjusted = <KWord>[
        for (final w in words)
          if (w.to > leading && w.from < leading + trimmed.length)
            KWord((w.from - leading).clamp(0, trimmed.length), (w.to - leading).clamp(0, trimmed.length), w.start, w.end),
      ];
      lines.add(LyricLine(lineStart ?? (adjusted.isEmpty ? null : adjusted.first.start), trimmed, adjusted.isEmpty ? null : adjusted));
    }
    if (lines.isEmpty) return null;
    final synced = lines.every((l) => l.at != null);
    if (synced) lines.sort((a, b) => a.at!.compareTo(b.at!));
    return Lyrics(synced ? lines : [for (final l in lines) LyricLine(null, l.text)], synced: synced, origin: 'betterlyrics');
  }
}
