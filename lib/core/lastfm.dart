import 'dart:async';
import 'dart:convert';

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

/// Похожесть по Last.fm: строится на том, что миллионы людей слушают подряд.
/// Даёт похожие треки (а не только исполнителей), поэтому волна держит настроение песни.
/// Запросы идут по одному с паузой, ответы хранятся неделю — API не перегружаем.
class LastFm {
  final AppStore store;
  LastFm(this.store);

  static const _ttl = Duration(days: 7);
  final http.Client _http = http.Client();
  final Map<String, (DateTime, List<LfmItem>)> _cache = {};
  final Map<String, Future<List<LfmItem>>> _inflight = {};
  Future<void> _queue = Future.value();
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  bool _loaded = false;
  Timer? _saveTimer;

  /// Пока ключ не отвергнут: при ошибке ключа перестаём спрашивать до перезапуска
  bool _keyOk = true;
  bool get available => kLastFmKey.isNotEmpty && _keyOk;

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final j = await store.readJson('lastfm.json');
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
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 5), () async {
      // Самые старые ответы выбрасываем, чтобы файл не рос бесконечно
      final entries = _cache.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
      final keep = entries.take(600);
      try {
        await store.writeJson('lastfm.json', {
          for (final e in keep) e.key: {'at': e.value.$1.toUtc().toIso8601String(), 'items': [for (final i in e.value.$2) i.toJson()]},
        });
      } catch (e) {
        AppLog.warn('Last.fm: не сохранился кеш', e);
      }
    });
  }

  /// Похожие на трек: до 50 штук, самые похожие первыми
  Future<List<LfmItem>> similarTracks(String artist, String title) => _get(
        't:${artist.toLowerCase()}|${title.toLowerCase()}',
        {'method': 'track.getsimilar', 'artist': artist, 'track': title, 'limit': '50'},
        (j) {
          final list = (j['similartracks'] as Map?)?['track'];
          return [
            for (final x in (list is List ? list : const []))
              if (x is Map) LfmItem('${(x['artist'] as Map?)?['name'] ?? ''}', '${x['name'] ?? ''}', _num(x['match']))
          ];
        },
      );

  /// Похожие исполнители
  Future<List<LfmItem>> similarArtists(String artist) => _get(
        'a:${artist.toLowerCase()}',
        {'method': 'artist.getsimilar', 'artist': artist, 'limit': '30'},
        (j) {
          final list = (j['similarartists'] as Map?)?['artist'];
          return [
            for (final x in (list is List ? list : const []))
              if (x is Map) LfmItem('${x['name'] ?? ''}', '', _num(x['match']))
          ];
        },
      );

  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  Future<List<LfmItem>> _get(String key, Map<String, String> q, List<LfmItem> Function(Map) parse) async {
    if (!available) return const [];
    await _load();
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < _ttl) return hit.$2;
    return _inflight[key] ??= _fetch(key, q, parse).whenComplete(() => _inflight.remove(key));
  }

  Future<List<LfmItem>> _fetch(String key, Map<String, String> q, List<LfmItem> Function(Map) parse) {
    final done = Completer<List<LfmItem>>();
    // По одному запросу за раз и не чаще четырёх в секунду
    _queue = _queue.then((_) async {
      final wait = const Duration(milliseconds: 250) - DateTime.now().difference(_last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _last = DateTime.now();
      try {
        final res = await _http
            .get(Uri.https('ws.audioscrobbler.com', '/2.0/',
                {...q, 'api_key': kLastFmKey, 'format': 'json', 'autocorrect': '1'}))
            .timeout(const Duration(seconds: 12));
        final j = jsonDecode(utf8.decode(res.bodyBytes));
        if (j is! Map) throw const FormatException('не JSON');
        final err = (j['error'] as num?)?.toInt();
        if (err == 10 || err == 26) {
          _keyOk = false;
          AppLog.warn('Last.fm: ключ не принят (${j['message']})');
          done.complete(const []);
          return;
        }
        if (err == 29) {
          // Слишком часто — притормозим и не будем запоминать пустой ответ
          _last = DateTime.now().add(const Duration(seconds: 5));
          done.complete(const []);
          return;
        }
        // 6 — «не найдено»: тоже ответ, запоминаем, чтобы не спрашивать снова
        final items = err == null ? parse(j).where((i) => i.artist.isNotEmpty).toList() : <LfmItem>[];
        _cache[key] = (DateTime.now(), items);
        _save();
        done.complete(items);
      } catch (e) {
        done.complete(const []); // сеть — без кеша, спросим позже
      }
    });
    return done.future;
  }
}
