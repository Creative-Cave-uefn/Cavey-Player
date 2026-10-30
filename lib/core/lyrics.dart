// Тексты песен из открытой базы LRCLIB (lrclib.net). Синхронные тексты
// (с временем каждой строки) подсвечиваются по ходу песни. Ответы кэшируются
// на диске; если текста нет, повторно спрашиваем не раньше чем через неделю.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'log.dart';
import 'models.dart';

/// Кусок строки со своим временем: слово или слог. [from]–[to] — символы в тексте строки
class KWord {
  final int from, to;
  final Duration start, end;
  const KWord(this.from, this.to, this.start, this.end);

  List<int> toJson() => [from, to, start.inMilliseconds, end.inMilliseconds];
  static KWord? fromJson(dynamic j) {
    if (j is! List || j.length < 4) return null;
    return KWord((j[0] as num).toInt(), (j[1] as num).toInt(), Duration(milliseconds: (j[2] as num).toInt()),
        Duration(milliseconds: (j[3] as num).toInt()));
  }
}

class LyricLine {
  final Duration? at;
  final String text;

  /// Время каждого слова, если оно известно (расширенный LRC с отметками внутри строки)
  final List<KWord>? words;
  const LyricLine(this.at, this.text, [this.words]);
}

/// Слоги строки для караоке, когда точного времени слов нет: строка делится на слоги
/// (по гласным; японская азбука и иероглифы — по знаку), и они загораются по очереди.
/// Певцы обычно тянут последнюю ноту, поэтому слоги укладываются не во всю строку, а в её начало
List<KWord> syllables(String text, Duration start, Duration end) {
  final ranges = syllableRanges(text);
  if (ranges.isEmpty) return const [];
  final total = (end - start).inMilliseconds;
  if (total <= 0) return [for (final r in ranges) KWord(r.$1, r.$2, start, start)];
  // Обычно поют 3–6 слогов в секунду: строку с долгой паузой в конце не растягиваем на всю длину
  final weight = ranges.fold<double>(0, (a, r) => a + r.$3);
  // Длинный проигрыш до следующей строки не растягивает слоги: заливка идёт в темпе пения
  final active = math.min(total * 0.9, weight * 420).toDouble();
  final out = <KWord>[];
  var acc = 0.0;
  for (final r in ranges) {
    final a = start + Duration(milliseconds: (active * acc / weight).round());
    acc += r.$3;
    final b = start + Duration(milliseconds: (active * acc / weight).round());
    out.add(KWord(r.$1, r.$2, a, b));
  }
  return out;
}

final _cjk = RegExp(r'[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]');
final _vowel = RegExp(r'[aeiouyаеёиоуыэюяіїєæøåäöüéèêáàíóúAEIOUYАЕЁИОУЫЭЮЯІЇЄÆØÅÄÖÜÉÈÊÁÀÍÓÚ]');
final _letter = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Слоги строки: (начало, конец, вес). Вес больше у слога в конце слова — там обычно короткая пауза
List<(int, int, double)> syllableRanges(String text) {
  final out = <(int, int, double)>[];
  final words = RegExp(r'\S+').allMatches(text);
  for (final w in words) {
    final s = w.start, e = w.end;
    final word = text.substring(s, e);
    if (!_letter.hasMatch(word)) continue; // «—», «...»
    if (_cjk.hasMatch(word)) {
      // Азбука и иероглифы: каждый знак — отдельный слог
      for (var i = s; i < e; i++) {
        if (_letter.hasMatch(text[i])) out.add((i, i + 1, i == e - 1 ? 1.3 : 1.0));
      }
      continue;
    }
    // Ищем группы гласных: каждая — ядро слога. Согласная перед гласной уходит в её слог
    final nuclei = <(int, int)>[];
    var i = s;
    while (i < e) {
      if (_vowel.hasMatch(text[i])) {
        final a = i;
        while (i < e && _vowel.hasMatch(text[i])) {
          i++;
        }
        nuclei.add((a, i));
      } else {
        i++;
      }
    }
    if (nuclei.length <= 1) {
      out.add((s, e, 1.3));
      continue;
    }
    var from = s;
    for (var k = 0; k < nuclei.length; k++) {
      final last = k == nuclei.length - 1;
      int to;
      if (last) {
        to = e;
      } else {
        final gapStart = nuclei[k].$2, nextVowel = nuclei[k + 1].$1;
        // между гласными одна согласная — она уходит к следующему слогу; больше — делим пополам
        to = nextVowel - gapStart <= 1 ? gapStart : gapStart + (nextVowel - gapStart) ~/ 2;
      }
      out.add((from, to, last ? 1.3 : 1.0));
      from = to;
    }
  }
  return out;
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
        final body = raw.substring(tags.last.end);
        // Расширенный LRC: <мм:сс.xx> перед каждым словом — точное время слов
        final (text, words) = _words(body, shift);
        for (final m in tags) {
          final min = int.parse(m.group(1)!);
          final sec = double.parse(m.group(2)!.replaceAll(':', '.'));
          final ms = ((min * 60 + sec) * 1000).round() - shift;
          lines.add(LyricLine(Duration(milliseconds: ms < 0 ? 0 : ms), text, words));
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

  static final _wordTag = RegExp(r'<(\d+):(\d+(?:[.:]\d+)?)>');

  /// Текст строки без отметок и время слов из отметок <мм:сс.xx>. Отметок нет — слов нет
  static (String, List<KWord>?) _words(String body, int shift) {
    final marks = _wordTag.allMatches(body).toList();
    if (marks.isEmpty) return (body.trim(), null);
    Duration at(RegExpMatch m) {
      final ms = ((int.parse(m.group(1)!) * 60 + double.parse(m.group(2)!.replaceAll(':', '.'))) * 1000).round() - shift;
      return Duration(milliseconds: ms < 0 ? 0 : ms);
    }

    final buf = StringBuffer();
    final pieces = <(int, int, Duration)>[];
    var cursor = 0;
    Duration? pending;
    for (final m in marks) {
      final chunk = body.substring(cursor, m.start);
      if (chunk.isNotEmpty) {
        final from = buf.length;
        buf.write(chunk);
        if (pending != null && chunk.trim().isNotEmpty) pieces.add((from, buf.length, pending));
      }
      pending = at(m);
      cursor = m.end;
    }
    final tail = body.substring(cursor);
    if (tail.isNotEmpty) {
      final from = buf.length;
      buf.write(tail);
      if (pending != null && tail.trim().isNotEmpty) pieces.add((from, buf.length, pending));
    }
    // Пробелы по краям убираем, сдвигая отметки
    final raw = buf.toString();
    final lead = raw.length - raw.trimLeft().length;
    final text = raw.trim();
    final words = <KWord>[];
    for (var i = 0; i < pieces.length; i++) {
      final p = pieces[i];
      final end = i + 1 < pieces.length ? pieces[i + 1].$3 : (marks.last.end == body.length ? at(marks.last) : p.$3 + const Duration(milliseconds: 600));
      words.add(KWord((p.$1 - lead).clamp(0, text.length), (p.$2 - lead).clamp(0, text.length), p.$3, end));
    }
    return (text, words.isEmpty ? null : words);
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
