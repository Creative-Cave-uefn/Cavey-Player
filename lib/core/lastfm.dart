import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;

import 'package:http/http.dart' as http;

import '../config.dart';
import 'log.dart';
import 'store.dart';

/// Похожий трек или исполнитель из Last.fm: [match] от 0 до 1
class LfmItem {
  final String artist;
  final String title; // пусто для исполнителя
  final double match;
  const LfmItem(this.artist, this.title, this.match);

  List<dynamic> toJson() => [artist, title, match];
  static LfmItem? fromJson(dynamic j) {
    if (j is! List || j.length < 3) return null;
    return LfmItem('${j[0]}', '${j[1]}', (j[2] as num?)?.toDouble() ?? 0);
  }
}

/// Запрос в очереди: [prio] 1 — нужен прямо сейчас (играет трек, ищем новинку), 0 — фоновый (теги)
class _Req {
  final int prio;
  final int seq;
  final Future<void> Function() run;
  _Req(this.prio, this.seq, this.run);
}

/// Похожесть по Last.fm: строится на том, что миллионы людей слушают подряд.
/// Даёт похожие треки (а не только исполнителей), поэтому волна держит настроение песни.
///
/// Запросы идут по одному с паузой, ответы хранятся неделю — API не перегружаем.
/// Важное про ошибки: ответ «не найдено» запоминается, а сбой (таймаут, 5xx, не-JSON, временная ошибка
/// Last.fm) — нет. Сбой возвращается как `null`, чтобы вызывающий не принял его за «данных нет».
/// Если подряд случилось три сбоя, Last.fm считается недоступным и на время паузы все запросы
/// отвечают сразу, а не по 8 секунд каждый.
class LastFm {
  /// [store] может быть null (тесты): тогда кеш живёт только в памяти
  final AppStore? store;
  LastFm(this.store,
      {http.Client? client, Duration timeout = const Duration(seconds: 8), Duration spacing = const Duration(milliseconds: 250)})
      : _http = client ?? http.Client(),
        _timeout = timeout,
        _spacing = spacing;

  static const _ttl = Duration(days: 7);
  static final _never = DateTime.fromMillisecondsSinceEpoch(0);

  final http.Client _http;
  final Duration _timeout;
  final Duration _spacing;
  final Map<String, (DateTime, List<LfmItem>)> _cache = {};
  final Map<String, Future<List<LfmItem>?>> _inflight = {};
  final List<_Req> _waiting = [];
  bool _pumping = false;
  int _seq = 0;
  DateTime _last = _never;
  Future<void>? _loading;
  Timer? _saveTimer;

  /// Пока ключ не отвергнут: при ошибке ключа перестаём спрашивать до перезапуска
  bool _keyOk = true;
  bool get available => kLastFmKey.isNotEmpty && _keyOk;

  // ---------- пауза при сбоях ----------

  int _fails = 0; // подряд неудачных запросов
  int _trips = 0; // сколько раз подряд срабатывала пауза: растёт, пока Last.fm не ответит
  DateTime _pausedUntil = _never;
  String _pauseWhy = '';

  /// Last.fm сейчас не спрашиваем: недавно подряд не ответил или просил подождать
  bool get paused => DateTime.now().isBefore(_pausedUntil);

  Duration get pauseLeft {
    final left = _pausedUntil.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Почему Last.fm не работает, для строки в интерфейсе. Пусто — всё в порядке
  String get status {
    if (!_keyOk) return 'Last.fm: ключ не принят';
    if (!paused) return '';
    final left = pauseLeft;
    final t = left.inMinutes >= 1 ? '${left.inMinutes + 1} мин' : '${left.inSeconds + 1} с';
    return 'Last.fm недоступен ($_pauseWhy), повторю через $t';
  }

  void _fail(String why) {
    if (++_fails < 3) return;
    _fails = 0;
    _trips++;
    _pause(Duration(minutes: const [1, 2, 5, 10][min(_trips, 4) - 1]), why);
  }

  void _pause(Duration d, String why) {
    _pausedUntil = DateTime.now().add(d);
    _pauseWhy = why;
    AppLog.warn('Last.fm: пауза ${d.inSeconds} с ($why)');
  }

  void _ok() {
    _fails = 0;
    _trips = 0;
    _pausedUntil = _never;
    _pauseWhy = '';
  }

  // ---------- кеш ----------

  Future<void> _load() => _loading ??= _doLoad();

  Future<void> _doLoad() async {
    try {
      final j = await store?.readJson('lastfm.json');
      if (j is! Map) return;
      j.forEach((k, v) {
        if (v is! Map) return;
        final at = DateTime.tryParse('${v['at']}');
        if (at == null || DateTime.now().difference(at) > _ttl) return;
        _cache['$k'] = (at, [for (final x in (v['items'] as List? ?? const [])) if (LfmItem.fromJson(x) case final i?) i]);
      });
    } catch (_) {}
  }

  void _save() {
    final s = store;
    if (s == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 5), () async {
      // Самые старые ответы выбрасываем, чтобы файл не рос бесконечно
      final entries = _cache.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
      final keep = entries.take(600);
      try {
        await s.writeJson('lastfm.json', {
          for (final e in keep) e.key: {'at': e.value.$1.toUtc().toIso8601String(), 'items': [for (final i in e.value.$2) i.toJson()]},
        });
      } catch (e) {
        AppLog.warn('Last.fm: не сохранился кеш', e);
      }
    });
  }

  /// Название без «(feat. …)», «[Remastered]», «- Radio Edit» и т. п.: с ними Last.fm часто не узнаёт песню
  static String cleanTitle(String t) {
    var s = t.replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '');
    s = s.replaceAll(RegExp(r'\s+[-–—]\s+.*(remaster|edit|version|mix|live|mono|stereo|bonus|demo).*$', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'\s+(feat|ft)\.?\s.*$', caseSensitive: false), '');
    s = s.trim();
    return s.isEmpty ? t.trim() : s;
  }

  // ---------- запросы ----------
  // Первые четыре при сбое возвращают пустой список (им всё равно: нет данных — нет подсказки).
  // Теги возвращают null при сбое, потому что их результат запоминается надолго.

  /// Похожие на трек: до 100 штук, самые похожие первыми
  Future<List<LfmItem>> similarTracks(String artist, String title) async =>
      await _get(
        't:${artist.toLowerCase()}|${cleanTitle(title).toLowerCase()}',
        {'method': 'track.getsimilar', 'artist': artist, 'track': cleanTitle(title), 'limit': '100'},
        (j) {
          final list = (j['similartracks'] as Map?)?['track'];
          return [
            for (final x in (list is List ? list : const []))
              if (x is Map) LfmItem('${(x['artist'] as Map?)?['name'] ?? ''}', '${x['name'] ?? ''}', _num(x['match']))
          ];
        },
      ) ??
      const [];

  /// Похожие исполнители
  Future<List<LfmItem>> similarArtists(String artist) async =>
      await _get(
        'a:${artist.toLowerCase()}',
        {'method': 'artist.getsimilar', 'artist': artist, 'limit': '30'},
        (j) {
          final list = (j['similarartists'] as Map?)?['artist'];
          return [
            for (final x in (list is List ? list : const []))
              if (x is Map) LfmItem('${x['name'] ?? ''}', '', _num(x['match']))
          ];
        },
      ) ??
      const [];

  /// Самые популярные песни исполнителя: [match] — от 1 у первой до 0 у последней
  Future<List<LfmItem>> topTracks(String artist) async =>
      await _get(
        'top:${artist.toLowerCase()}',
        {'method': 'artist.gettoptracks', 'artist': artist, 'limit': '30'},
        (j) {
          final list = (j['toptracks'] as Map?)?['track'];
          final l = list is List ? list : const [];
          return [
            for (var i = 0; i < l.length; i++)
              if (l[i] is Map)
                LfmItem('${((l[i] as Map)['artist'] as Map?)?['name'] ?? artist}', '${(l[i] as Map)['name'] ?? ''}',
                    1 - i / l.length)
          ];
        },
      ) ??
      const [];

  /// Самые популярные песни с тегом (настроением)
  Future<List<LfmItem>> tagTracks(String tag) async =>
      await _get(
        'tag:$tag',
        {'method': 'tag.gettoptracks', 'tag': tag, 'limit': '100'},
        (j) {
          final list = (j['tracks'] as Map?)?['track'];
          final l = list is List ? list : const [];
          return [
            for (var i = 0; i < l.length; i++)
              if (l[i] is Map)
                LfmItem('${((l[i] as Map)['artist'] as Map?)?['name'] ?? ''}', '${(l[i] as Map)['name'] ?? ''}', 1 - i / l.length)
          ];
        },
      ) ??
      const [];

  static List<LfmItem> _tags(Map j) {
    final list = (j['toptags'] as Map?)?['tag'];
    return [
      for (final x in (list is List ? list : const []))
        if (x is Map && _num(x['count']) >= 5) LfmItem('${x['name'] ?? ''}'.toLowerCase(), '', _num(x['count']) / 100)
    ].take(20).toList();
  }

  /// Теги исполнителя (жанры и настроения): в [artist] — название тега, [match] — вес от 0 до 1.
  /// `null` — Last.fm не ответил; пустой список — ответил, что тегов нет. Запрос фоновый
  Future<List<LfmItem>?> artistTags(String artist) =>
      _get('tags:${artist.toLowerCase()}', {'method': 'artist.gettoptags', 'artist': artist}, _tags, prio: 0);

  /// Теги конкретной песни (Д5): точнее, чем теги исполнителя. `null` — Last.fm не ответил. Запрос фоновый
  Future<List<LfmItem>?> trackTags(String artist, String title) => _get(
      'ttags:${artist.toLowerCase()}|${title.toLowerCase()}', {'method': 'track.gettoptags', 'artist': artist, 'track': title}, _tags,
      prio: 0);

  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  Future<List<LfmItem>?> _get(String key, Map<String, String> q, List<LfmItem> Function(Map) parse, {int prio = 1}) async {
    if (!available) return null;
    await _load();
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < _ttl) return hit.$2;
    if (paused) return null;
    return _inflight[key] ??= _fetch(q, key, parse, prio).whenComplete(() => _inflight.remove(key));
  }

  Future<List<LfmItem>?> _fetch(Map<String, String> q, String key, List<LfmItem> Function(Map) parse, int prio) {
    final done = Completer<List<LfmItem>?>();
    _waiting.add(_Req(prio, _seq++, () async {
      List<LfmItem>? result;
      try {
        result = await _request(key, q, parse);
      } catch (e) {
        AppLog.warn('Last.fm: запрос не удался', e);
      } finally {
        // Завершаем ровно один раз и при любом исходе: иначе вызывающий завис бы навсегда
        if (!done.isCompleted) done.complete(result);
      }
    }));
    unawaited(_pump());
    return done.future;
  }

  /// По одному запросу за раз, не чаще раз в [_spacing]; срочные обгоняют фоновые.
  /// Любая ошибка внутри запроса ловится в [_fetch], поэтому очередь не может «умереть»
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_waiting.isNotEmpty) {
        _waiting.sort((a, b) => a.prio != b.prio ? b.prio.compareTo(a.prio) : a.seq.compareTo(b.seq));
        final r = _waiting.removeAt(0);
        final wait = _spacing - DateTime.now().difference(_last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        _last = DateTime.now();
        await r.run();
      }
    } finally {
      _pumping = false;
    }
  }

  Future<List<LfmItem>?> _request(String key, Map<String, String> q, List<LfmItem> Function(Map) parse) async {
    if (paused || !available) return null; // пока ждали своей очереди, Last.fm успел «упасть»
    final http.Response res;
    try {
      res = await _http
          .get(Uri.https('ws.audioscrobbler.com', '/2.0/', {...q, 'api_key': kLastFmKey, 'format': 'json', 'autocorrect': '1'}))
          .timeout(_timeout);
    } on TimeoutException {
      _fail('нет ответа');
      return null;
    } catch (_) {
      _fail('нет связи');
      return null;
    }
    dynamic j;
    try {
      j = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {}
    if (j is! Map) {
      // Страница-заглушка провайдера, 502 от прокси и т. п. — это сбой, а не «данных нет»
      _fail('ответ ${res.statusCode}');
      return null;
    }
    final err = (j['error'] as num?)?.toInt();
    if (err == 10 || err == 26) {
      _keyOk = false;
      AppLog.warn('Last.fm: ключ не принят (${j['message']})');
      return null;
    }
    if (err == 29) {
      _pause(const Duration(seconds: 30), 'лимит запросов'); // не сбой сети: просто подождём
      return null;
    }
    if (err == 8 || err == 11 || err == 16) {
      _fail('сервис ответил ошибкой $err'); // временная ошибка Last.fm — не запоминаем
      return null;
    }
    // Сюда доходят и успешные ответы, и 6 — «не найдено»: это настоящий ответ, его запоминаем
    final List<LfmItem> items;
    try {
      items = err == null ? parse(j).where((i) => i.artist.isNotEmpty).toList() : <LfmItem>[];
    } catch (e) {
      AppLog.warn('Last.fm: неожиданный ответ на ${q['method']}', e);
      _fail('странный ответ');
      return null;
    }
    _ok();
    _cache[key] = (DateTime.now(), items);
    _save();
    return items;
  }
}
