// Тексты песен из открытой базы LRCLIB (lrclib.net). Синхронные тексты
// (с временем каждой строки) подсвечиваются по ходу песни. Ответы кэшируются
// на диске; если текста нет, повторно спрашиваем не раньше чем через неделю.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
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
  static final _offset = RegExp(r'^\s*\[offset:\s*([+-]?\d+)\s*\]', multiLine: true, caseSensitive: false);

  static Lyrics? fromLrclib(Map j) {
    if (j['instrumental'] == true) return const Lyrics([], synced: false, instrumental: true);
    final synced = j['syncedLyrics'] as String?;
    if (synced != null && synced.trim().isNotEmpty) {
      // [offset:+500] — строки надо показывать на полсекунды раньше
      final shift = int.tryParse(_offset.firstMatch(synced)?.group(1)?.replaceAll('+', '') ?? '') ?? 0;
      final lines = <LyricLine>[];
      for (final raw in const LineSplitter().convert(synced)) {
        final tags = _tag.allMatches(raw).toList();
        if (tags.isEmpty) continue;
        final text = raw.substring(tags.last.end).trim();
        for (final m in tags) {
          final min = int.parse(m.group(1)!);
          final sec = double.parse(m.group(2)!.replaceAll(':', '.'));
          final ms = ((min * 60 + sec) * 1000).round() - shift;
          lines.add(LyricLine(Duration(milliseconds: ms < 0 ? 0 : ms), text));
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
    var lo = 0, hi = lines.length - 1, idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].at! <= pos) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return idx;
  }
}

/// LRCLIB не отвечает (нет сети или сервис перегружен) — это не то же самое, что «текста нет»
class LyricsUnavailable implements Exception {}

/// Ищет и хранит тексты. Сообщает слушателям, когда любой поиск закончился:
/// панель показывает текст, как только он появился, кто бы его ни загрузил.
class LyricsService extends ChangeNotifier {
  final Directory dir;
  final Map<String, Lyrics?> _mem = {};
  final Map<String, Future<Lyrics?>> _inflight = {};

  /// Последний поиск не удался (LRCLIB не ответил) — до повторной попытки
  final Set<String> _failed = {};

  /// Не нашли, когда длительность трека была неизвестна: с длительностью стоит поискать ещё раз
  final Set<String> _noDuration = {};
  final http.Client _http = http.Client();

  static const _timeout = Duration(seconds: 8);

  LyricsService(this.dir);

  /// Ключ кэша по тому, что ищем, а не по id файла: если поправить название
  /// или исполнителя, текст поищется заново.
  static String keyFor(Track t) {
    final s = 'v2|${t.artist.trim().toLowerCase()}|${t.title.trim().toLowerCase()}|${t.album.trim().toLowerCase()}';
    return sha1.convert(utf8.encode(s)).toString().substring(0, 24);
  }

  /// Текст уже известен (в том числе «не нашёлся» — тогда [cached] вернёт null)
  bool known(Track t) => _mem.containsKey(keyFor(t));
  Lyrics? cached(Track t) => _mem[keyFor(t)];
  bool loading(Track t) => _inflight.containsKey(keyFor(t));
  bool failed(Track t) => _failed.contains(keyFor(t));

  /// [refresh] — забыть сохранённый ответ и спросить LRCLIB заново
  Future<Lyrics?> forTrack(Track t, Duration duration, {bool refresh = false}) {
    final key = keyFor(t);
    final running = _inflight[key];
    if (running != null) return running;
    // Не нашли без длительности, а теперь она известна — ищем ещё раз
    if (!refresh && duration > Duration.zero && _mem.containsKey(key) && _mem[key] == null && _noDuration.contains(key)) {
      refresh = true;
    }
    if (refresh) {
      _mem.remove(key);
    } else if (_mem.containsKey(key)) {
      return Future.value(_mem[key]);
    }
    _failed.remove(key);
    final f = _load(key, t, duration, refresh).then((l) {
      _mem[key] = l;
      if (l == null && duration <= Duration.zero) {
        _noDuration.add(key);
      } else {
        _noDuration.remove(key);
      }
      return l;
    }, onError: (Object e) {
      // Ошибку сети не запоминаем: в следующий раз попробуем снова
      _failed.add(key);
      throw e;
    }).whenComplete(() {
      _inflight.remove(key);
      notifyListeners();
    });
    _inflight[key] = f;
    notifyListeners();
    return f;
  }

  File _file(String key) => File('${dir.path}${Platform.pathSeparator}$key.json');

  Future<Lyrics?> _load(String key, Track t, Duration duration, bool refresh) async {
    final f = _file(key);
    if (!refresh) {
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
    }

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

  Map<String, String> get _headers =>
      {'User-Agent': 'CavePlayer/${kAppVersion.isEmpty ? 'dev' : kAppVersion} (github.com/$kReleasesRepo)'};

  /// Ответ LRCLIB: тело при 200, null при «не нашлось» или неподходящем запросе (400/404).
  /// Перегрузка (429, 5xx) и таймаут — исключение: это «не отвечает», а не «текста нет».
  Future<Object?> _get(String path, Map<String, String> q, {Duration timeout = _timeout}) async {
    var res = await _http.get(Uri.https('lrclib.net', path, q), headers: _headers).timeout(timeout);
    // Перегрузка (503 и т. п.) обычно короткая — одна повторная попытка чуть позже
    if (res.statusCode >= 500 || res.statusCode == 429) {
      await Future<void>.delayed(const Duration(seconds: 2));
      res = await _http.get(Uri.https('lrclib.net', path, q), headers: _headers).timeout(timeout);
    }
    if (res.statusCode == 200) return jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode == 400 || res.statusCode == 404) return null;
    throw HttpException('LRCLIB ответил ${res.statusCode} на $path');
  }

  Future<Map?> _fetch(Track t, Duration duration) async {
    final title = t.title.trim();
    final artist = t.artist.trim();
    final album = t.album.trim();
    if (title.isEmpty) return null;

    // Точный запрос: LRCLIB ждёт все четыре поля, без альбома или длительности сразу ищем
    if (artist.isNotEmpty && album.isNotEmpty && duration > Duration.zero) {
      final q = {'track_name': title, 'artist_name': artist, 'album_name': album, 'duration': '${duration.inSeconds}'};
      // Сначала только своя база (быстро), потом с поиском во внешних источниках (бывает долго)
      for (final (path, timeout) in [('/api/get-cached', _timeout), ('/api/get', const Duration(seconds: 12))]) {
        try {
          final j = await _get(path, q, timeout: timeout);
          if (j is Map && pickBest([j], duration) != null) return j;
        } on TimeoutException {
          // не дождались — поиск ниже всё равно может найти
        } on HttpException {
          // перегрузка на точном запросе — попробуем поиск
        }
      }
    }

    // Поиск: как есть, потом с очищенным названием и первым исполнителем, потом свободный запрос
    final cleanT = cleanTitle(title);
    final firstA = firstArtist(artist);
    final attempts = <Map<String, String>>[
      if (artist.isNotEmpty) {'track_name': title, 'artist_name': artist},
      if (artist.isNotEmpty && (cleanT != title || firstA != artist)) {'track_name': cleanT, 'artist_name': firstA},
      {'q': artist.isEmpty ? cleanT : '$firstA $cleanT'},
    ];
    for (final q in attempts) {
      final j = await _get('/api/search', q);
      if (j is! List) continue;
      final best = pickBest(j.whereType<Map>().toList(), duration);
      if (best != null) return best;
    }
    return null;
  }

  /// Лучший вариант из ответа: есть текст, длительность не дальше 10 секунд,
  /// среди близких по длительности (до 3 секунд) — синхронный.
  static Map? pickBest(List<Map> list, Duration duration) {
    bool synced(Map m) => (m['syncedLyrics'] as String?)?.trim().isNotEmpty ?? false;
    bool hasText(Map m) => m['instrumental'] == true || synced(m) || ((m['plainLyrics'] as String?)?.trim().isNotEmpty ?? false);
    final candidates = list.where(hasText).toList();
    if (candidates.isEmpty) return null;
    if (duration <= Duration.zero) {
      return candidates.firstWhere(synced, orElse: () => candidates.first);
    }
    final secs = duration.inMilliseconds / 1000;
    double diff(Map m) => (((m['duration'] as num?) ?? -1000) - secs).abs().toDouble();
    final near = candidates.where((m) => diff(m) <= 10).toList();
    if (near.isEmpty) return null; // слишком разные — вероятно, другая версия песни
    int rank(Map m) => (diff(m) <= 3 ? 0 : 2) + (synced(m) ? 0 : 1);
    near.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : diff(a).compareTo(diff(b));
    });
    return near.first;
  }

  static final _junk = RegExp(
    r'\s*[\(\[][^\)\]]*(official|video|audio|lyric|clip|клип|remaster|visuali[sz]er|\bhq\b|\bhd\b|4k|feat\.?|ft\.)[^\)\]]*[\)\]]',
    caseSensitive: false,
    unicode: true,
  );
  static final _tailRemaster = RegExp(r'\s+-\s+(\d{4}\s+)?remaster(ed)?(\s+\d{4})?.*$', caseSensitive: false);
  static final _tailFeat = RegExp(r'\s+(feat\.?|ft\.)\s+.*$', caseSensitive: false);

  /// «Песня (Official Video) [feat. X] - 2011 Remaster» → «Песня»
  static String cleanTitle(String s) {
    final r = s.replaceAll(_junk, '').replaceAll(_tailRemaster, '').replaceAll(_tailFeat, '').trim();
    return r.isEmpty ? s.trim() : r;
  }

  static final _artistSep = RegExp(r'\s*(?:,|;|&|/|\s(?:feat\.?|ft\.|x|vs\.?)\s)\s*', caseSensitive: false);

  /// «A, B feat. C» → «A»
  static String firstArtist(String s) {
    final r = s.split(_artistSep).first.trim();
    return r.isEmpty ? s.trim() : r;
  }
}
