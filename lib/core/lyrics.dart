// Тексты песен из открытой базы LRCLIB (lrclib.net). Синхронные тексты
// (с временем каждой строки) подсвечиваются по ходу песни. Ответы кэшируются
// на диске; если текста нет, повторно спрашиваем не раньше чем через неделю.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'log.dart';
import 'models.dart';

class LyricLine {
  final Duration? at;
  final String text;
  const LyricLine(this.at, this.text);
}

class Lyrics {
  final List<LyricLine> lines;
  final bool synced;
  final bool instrumental;
  const Lyrics(this.lines, {required this.synced, this.instrumental = false});

  static final _tag = RegExp(r'\[(\d+):(\d+(?:[.:]\d+)?)\]');

  static Lyrics? fromLrclib(Map j) {
    if (j['instrumental'] == true) return const Lyrics([], synced: false, instrumental: true);
    final synced = j['syncedLyrics'] as String?;
    if (synced != null && synced.trim().isNotEmpty) {
      final lines = <LyricLine>[];
      for (final raw in const LineSplitter().convert(synced)) {
        final tags = _tag.allMatches(raw).toList();
        if (tags.isEmpty) continue;
        final text = raw.substring(tags.last.end).trim();
        for (final m in tags) {
          final min = int.parse(m.group(1)!);
          final sec = double.parse(m.group(2)!.replaceAll(':', '.'));
          lines.add(LyricLine(Duration(milliseconds: ((min * 60 + sec) * 1000).round()), text));
        }
      }
      lines.sort((a, b) => a.at!.compareTo(b.at!));
      if (lines.isNotEmpty) return Lyrics(lines, synced: true);
    }
    final plain = j['plainLyrics'] as String?;
    if (plain != null && plain.trim().isNotEmpty) {
      return Lyrics([for (final l in const LineSplitter().convert(plain)) LyricLine(null, l.trim())], synced: false);
    }
    return null;
  }

  /// Индекс строки, которая звучит сейчас
  int indexAt(Duration pos) {
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].at! <= pos) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }
}

/// LRCLIB не отвечает (нет сети или сервис перегружен) — это не то же самое, что «текста нет»
class LyricsUnavailable implements Exception {}

class LyricsService {
  final Directory dir;
  final Map<String, Lyrics?> _mem = {};
  final Map<String, Future<Lyrics?>> _inflight = {};
  final http.Client _http = http.Client();

  LyricsService(this.dir);

  Future<Lyrics?> forTrack(Track t, Duration duration) {
    if (_mem.containsKey(t.id)) return Future.value(_mem[t.id]);
    // Ошибку сети не запоминаем: в следующий раз попробуем снова
    return _inflight[t.id] ??= _load(t, duration).then((l) {
      _mem[t.id] = l;
      return l;
    }).whenComplete(() => _inflight.remove(t.id));
  }

  File _file(String id) => File('${dir.path}${Platform.pathSeparator}$id.json');

  Future<Lyrics?> _load(Track t, Duration duration) async {
    final f = _file(t.id);
    try {
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map;
        if (j['none'] == true) {
          final at = DateTime.tryParse('${j['at']}');
          if (at != null && DateTime.now().difference(at) < const Duration(days: 7)) return null;
        } else {
          return Lyrics.fromLrclib(j);
        }
      }
    } catch (_) {}

    Map? found;
    try {
      found = await _fetch(t, duration);
    } catch (e) {
      AppLog.warn('LRCLIB не ответил для «${t.title}»', e);
      throw LyricsUnavailable();
    }
    try {
      await f.writeAsString(jsonEncode(found ?? {'none': true, 'at': DateTime.now().toIso8601String()}));
    } catch (_) {}
    return found == null ? null : Lyrics.fromLrclib(found);
  }

  Future<Map?> _fetch(Track t, Duration duration) async {
    final headers = {'User-Agent': 'CavePlayer/${kAppVersion.isEmpty ? 'dev' : kAppVersion} (github.com/$kReleasesRepo)'};
    final title = t.title.trim();
    final artist = t.artist.trim();
    if (title.isEmpty) return null;

    if (artist.isNotEmpty) {
      final q = {
        'track_name': title,
        'artist_name': artist,
        if (t.album.isNotEmpty) 'album_name': t.album,
        if (duration > Duration.zero) 'duration': '${duration.inSeconds}',
      };
      final res = await _http.get(Uri.https('lrclib.net', '/api/get', q), headers: headers);
      if (res.statusCode == 200) return jsonDecode(res.body) as Map;
      if (res.statusCode != 404) throw HttpException('LRCLIB ответил ${res.statusCode}');
    }

    // Точного совпадения нет — ищем и выбираем ближайшее по длительности
    final res = await _http.get(
      Uri.https('lrclib.net', '/api/search', artist.isNotEmpty ? {'track_name': title, 'artist_name': artist} : {'q': title}),
      headers: headers,
    );
    if (res.statusCode != 200) throw HttpException('LRCLIB ответил ${res.statusCode}');
    final list = (jsonDecode(res.body) as List).whereType<Map>().toList();
    if (list.isEmpty) return null;
    if (duration > Duration.zero) {
      double diff(Map m) => (((m['duration'] as num?) ?? 0) - duration.inSeconds).abs().toDouble();
      list.sort((a, b) => diff(a).compareTo(diff(b)));
      if (diff(list.first) > 10) return null; // слишком разные — вероятно, другая песня
    }
    final withSync = list.where((m) => (m['syncedLyrics'] as String?)?.isNotEmpty ?? false);
    return withSync.isNotEmpty ? withSync.first : list.first;
  }
}
