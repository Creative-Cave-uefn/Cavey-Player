// Сведения об исполнителях из интернета: фото, альбомы и новинки, 30-секундные
// отрывки — из открытого API Deezer (без ключа), короткое описание — из Википедии.
// Всё кэшируется на диске: повторно спрашиваем не чаще раза в день (альбомы)
// или в неделю (фото и описание), чтобы не упираться в ограничения сервисов.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'library.dart';
import 'log.dart';
import 'models.dart';

class WebArtist {
  final int id;
  final String name;
  final String picture;
  final int fans;
  final String link;
  const WebArtist(this.id, this.name, this.picture, this.fans, this.link);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'pic': picture, 'fans': fans, 'link': link};
  static WebArtist fromDeezer(Map a) => WebArtist((a['id'] as num).toInt(), '${a['name']}',
      '${a['picture_xl'] ?? a['picture_big'] ?? a['picture_medium'] ?? ''}', (a['nb_fan'] as num?)?.toInt() ?? 0, '${a['link'] ?? ''}');

  static WebArtist fromJson(Map j) =>
      WebArtist((j['id'] as num).toInt(), '${j['name']}', '${j['pic'] ?? ''}', (j['fans'] as num?)?.toInt() ?? 0, '${j['link'] ?? ''}');
}

class WebAlbum {
  final int id;
  final String title;
  final String cover;
  final String date; // ГГГГ-ММ-ДД
  final String type; // album, single, ep, compile
  final String artist;
  final String link;
  final int artistId;
  final int tracks; // число треков, если известно
  const WebAlbum(this.id, this.title, this.cover, this.date, this.type, this.artist, this.link, {this.artistId = 0, this.tracks = 0});

  String get year => date.length >= 4 ? date.substring(0, 4) : '';
  String get typeLabel => switch (type) { 'single' => 'Сингл', 'ep' => 'EP', 'compile' => 'Сборник', _ => 'Альбом' };
  DateTime? get released => DateTime.tryParse(date);

  Map<String, dynamic> toJson() =>
      {'id': id, 't': title, 'c': cover, 'd': date, 'k': type, 'a': artist, 'l': link, 'ai': artistId, 'n': tracks};
  static WebAlbum fromJson(Map j) => WebAlbum((j['id'] as num).toInt(), '${j['t']}', '${j['c'] ?? ''}', '${j['d'] ?? ''}',
      '${j['k'] ?? 'album'}', '${j['a'] ?? ''}', '${j['l'] ?? ''}',
      artistId: (j['ai'] as num?)?.toInt() ?? 0, tracks: (j['n'] as num?)?.toInt() ?? 0);

  /// Из ответа Deezer (альбом в списке, в поиске или отдельно)
  static WebAlbum fromDeezer(Map x, {String artist = '', int artistId = 0}) {
    final a = x['artist'] as Map?;
    return WebAlbum(
      (x['id'] as num).toInt(),
      '${x['title'] ?? ''}',
      '${x['cover_xl'] ?? x['cover_big'] ?? x['cover_medium'] ?? ''}',
      '${x['release_date'] ?? ''}',
      '${x['record_type'] ?? 'album'}',
      a?['name'] != null ? '${a!['name']}' : artist,
      '${x['link'] ?? ''}',
      artistId: (a?['id'] as num?)?.toInt() ?? artistId,
      tracks: (x['nb_tracks'] as num?)?.toInt() ?? 0,
    );
  }
}

class WebTrack {
  final int id;
  final String title;
  final String artist;
  final String preview; // 30 секунд mp3, может быть пустым
  final int seconds;
  final String link;
  final int artistId;
  final int albumId;
  final String album;
  final String cover;
  const WebTrack(this.id, this.title, this.artist, this.preview, this.seconds, this.link,
      {this.artistId = 0, this.albumId = 0, this.album = '', this.cover = ''});

  /// Из ответа Deezer; [album] — если трек пришёл в составе альбома
  static WebTrack fromDeezer(Map x, {Map? album}) {
    final a = x['artist'] as Map?;
    final al = (x['album'] as Map?) ?? album;
    return WebTrack(
      (x['id'] as num).toInt(),
      '${x['title'] ?? ''}',
      '${a?['name'] ?? ''}',
      '${x['preview'] ?? ''}',
      (x['duration'] as num?)?.toInt() ?? 0,
      '${x['link'] ?? ''}',
      artistId: (a?['id'] as num?)?.toInt() ?? 0,
      albumId: (al?['id'] as num?)?.toInt() ?? 0,
      album: '${al?['title'] ?? ''}',
      cover: '${al?['cover_medium'] ?? al?['cover_big'] ?? ''}',
    );
  }
}

class WebBio {
  final String text;
  final String url;
  const WebBio(this.text, this.url);
}

/// Новинка: альбом исполнителя из библиотеки, которого в библиотеке ещё нет
class NewRelease {
  final String artistKey;
  final WebAlbum album;
  const NewRelease(this.artistKey, this.album);
}

class WebInfoService extends ChangeNotifier {
  final Directory dir;
  final LibraryController lib;
  final http.Client _http = http.Client();

  WebInfoService(this.dir, this.lib) {
    unawaited(_load().then((_) => notifyListeners()));
  }

  static const _artistTtl = Duration(days: 7);
  static const _albumsTtl = Duration(hours: 20);

  // ---------- кэш на диске ----------

  Map<String, dynamic> _cache = {};
  bool _loaded = false;
  Timer? _saveTimer;

  File get _file => File('${dir.path}${Platform.pathSeparator}web_cache.json');

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (await _file.exists()) _cache = (jsonDecode(await _file.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      _cache = {};
    }
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () async {
      try {
        await _file.writeAsString(jsonEncode(_cache));
      } catch (e) {
        AppLog.warn('Не получилось сохранить кэш веб-сведений', e);
      }
    });
  }

  /// Запись есть и не устарела (значение может быть null — «не нашлось»)
  bool _isFresh(String key, Duration ttl) {
    final e = _cache[key];
    if (e is! Map) return false;
    final at = DateTime.tryParse('${e['at']}');
    return at != null && DateTime.now().difference(at) <= ttl;
  }

  Object? _value(String key) => (_cache[key] as Map?)?['v'];

  T? _fresh<T>(String key, Duration ttl, T Function(Object?) read) => _isFresh(key, ttl) ? read(_value(key)) : null;

  void _put(String key, Object? value) {
    _cache[key] = {'at': DateTime.now().toIso8601String(), 'v': value};
    _save();
  }

  // ---------- Deezer ----------

  // Deezer разрешает около 50 запросов за 5 секунд: не больше 4 одновременно и с паузой между ними.
  // Две очереди: важные запросы (новинки, страница исполнителя) идут первыми, фото для списка —
  // фоном. Фоновых ждёт не больше 24: фото строк, которые уже пролистали, просто отбрасываются.
  static const _parallel = 4;
  int _active = 0;
  final List<Completer<void>> _high = [];
  final List<Completer<void>> _low = [];
  DateTime _last = DateTime(0);

  Future<void> _slot(bool low) async {
    final busy = _active >= _parallel || (low && _high.isNotEmpty);
    if (!busy) {
      _active++;
    } else {
      final c = Completer<void>();
      if (low) {
        _low.add(c);
        // Свежие запросы — строки, которые сейчас на экране; отбрасываем самые старые (пролистанные)
        if (_low.length > 40) _low.removeAt(0).completeError(const _Dropped());
      } else {
        _high.add(c);
      }
      await c.future; // место передаётся из _free, счётчик уже учтён
    }
    final gap = const Duration(milliseconds: 120) - DateTime.now().difference(_last);
    if (gap > Duration.zero) await Future<void>.delayed(gap);
    _last = DateTime.now();
  }

  /// Состояние очереди к Deezer — для журнала
  String queueState() => 'запросов идёт: $_active, ждут: ${_high.length} важных и ${_low.length} фоновых, '
      'поисков в ожидании: ${_artistInflight.length}';

  void _free() {
    if (_high.isNotEmpty) {
      _high.removeAt(0).complete();
    } else if (_low.isNotEmpty) {
      _low.removeLast().complete(); // сначала то, что попросили последним — оно сейчас на экране
    } else {
      _active--;
    }
  }

  Future<Map> _deezer(String path, [Map<String, String>? q, bool low = false]) async {
    await _slot(low);
    try {
      try {
        return await _deezerRaw(path, q);
      } on _Quota {
        // Превысили частоту — Deezer просит подождать несколько секунд
        await Future<void>.delayed(const Duration(seconds: 5));
        return await _deezerRaw(path, q);
      }
    } finally {
      _free();
    }
  }

  Future<Map> _deezerRaw(String path, [Map<String, String>? q]) async {
    final res = await _http
        .get(Uri.https('api.deezer.com', path, q), headers: {'Accept-Language': 'ru,en'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 429) throw const _Quota();
    if (res.statusCode != 200) throw HttpException('Deezer ответил ${res.statusCode}');
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    if (j is! Map) throw const FormatException('Deezer: неожиданный ответ');
    final err = j['error'];
    if (err != null) {
      if (err is Map && (err['code'] == 4 || '${err['message']}'.toLowerCase().contains('quota'))) throw const _Quota();
      throw HttpException('Deezer: ${err is Map ? err['message'] : err}');
    }
    return j;
  }

  static String _key(String name) => name.trim().toLowerCase();
  static String _normTitle(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  final Map<String, Future<WebArtist?>> _artistInflight = {};

  /// Уже известное (из кэша) — для мгновенного показа
  WebArtist? artistCached(String name) {
    if (!_loaded) return null;
    return _fresh<WebArtist?>('artist:${_key(name)}', _artistTtl, (v) => v is Map ? WebArtist.fromJson(v) : null);
  }

  /// Исполнитель на Deezer по точному совпадению имени (самый популярный из одноимённых).
  /// [low] — фоновый запрос (фото в списке). Ошибки сети не запоминаются и дают null
  Future<WebArtist?> artist(String name, {bool low = false}) async {
    try {
      return await _lookup(name, low);
    } on _Dropped {
      return null;
    } catch (e) {
      AppLog.warn('Deezer: не нашёл «$name»', e);
      return null;
    }
  }

  /// Одинаковые поиски объединяются, но важный не ждёт фоновый (тот может долго стоять
  /// в очереди или быть отброшен): тогда важный ищет сам и подменяет фоновый
  Future<WebArtist?> _lookup(String name, bool low) {
    final k = _key(name);
    final running = _artistInflight[k];
    if (running != null && (low || !_inflightLow.contains(k))) return running;
    late final Future<WebArtist?> f;
    f = _search(name, low).whenComplete(() {
      if (identical(_artistInflight[k], f)) {
        _artistInflight.remove(k);
        _inflightLow.remove(k);
      }
    });
    _artistInflight[k] = f;
    if (low) {
      _inflightLow.add(k);
    } else {
      _inflightLow.remove(k);
    }
    return f;
  }

  final Set<String> _inflightLow = {};

  /// Сведения об исполнителе уже есть (в том числе «не нашёлся») или их сейчас ищут
  bool artistKnownOrLoading(String name) => _isFresh('artist:${_key(name)}', _artistTtl) || _artistInflight.containsKey(_key(name));

  /// Сам поиск (без объединения одинаковых запросов): новинки зовут его напрямую,
  /// чтобы не ждать фоновый запрос фото того же исполнителя
  Future<WebArtist?> _search(String name, bool low) async {
        await _load();
        final key = 'artist:${_key(name)}';
        if (_isFresh(key, _artistTtl)) {
          final v = _value(key);
          return v is Map ? WebArtist.fromJson(v) : null;
        }
        final j = await _deezer('/search/artist', {'q': name, 'limit': '8'}, low);
        final list = [for (final a in (j['data'] as List? ?? const [])) if (a is Map) a];
        Map? best;
        for (final a in list) {
          if (_key('${a['name']}') == _key(name)) {
            if (best == null || ((a['nb_fan'] as num?) ?? 0) > ((best['nb_fan'] as num?) ?? 0)) best = a;
          }
        }
        final w = best == null
            ? null
            : WebArtist((best['id'] as num).toInt(), '${best['name']}', '${best['picture_xl'] ?? best['picture_big'] ?? ''}',
                (best['nb_fan'] as num?)?.toInt() ?? 0, '${best['link'] ?? ''}');
        _put(key, w?.toJson());
        notifyListeners();
        return w;
  }

  /// Альбомы и синглы исполнителя, новые сверху
  Future<List<WebAlbum>> albums(WebArtist a) => albumsOf(a.id, a.name);

  Future<List<WebAlbum>> albumsOf(int artistId, String artistName) async {
    await _load();
    final a = (id: artistId, name: artistName);
    final key = 'albums:${a.id}';
    final hit = _fresh(key, _albumsTtl, (v) => [for (final x in (v as List)) WebAlbum.fromJson(x as Map)]);
    if (hit != null) return hit;
    final j = await _deezer('/artist/${a.id}/albums', {'limit': '100'});
    final list = [
      for (final x in (j['data'] as List? ?? const []))
        if (x is Map)
          WebAlbum.fromDeezer(x, artist: a.name, artistId: a.id)
    ]..sort((p, q) => q.date.compareTo(p.date));
    _put(key, [for (final x in list) x.toJson()]);
    return list;
  }

  final Map<int, List<WebTrack>> _tracks = {};

  /// Треки альбома с отрывками
  Future<List<WebTrack>> albumTracks(int albumId) async {
    final hit = _tracks[albumId];
    if (hit != null) return hit;
    final j = await _deezer('/album/$albumId/tracks', {'limit': '100'});
    final list = [
      for (final x in (j['data'] as List? ?? const []))
        if (x is Map)
          WebTrack.fromDeezer(x)
    ];
    return _tracks[albumId] = list;
  }

  // ---------- страницы исполнителя и альбома, поиск ----------

  final Map<int, WebArtist> _artistsById = {};
  final Map<int, List<WebTrack>> _top = {};
  final Map<int, List<WebArtist>> _related = {};
  final Map<int, (DateTime, List<WebTrack>)> _radio = {};

  /// «Радио» исполнителя: микс похожих песен разных артистов, который Deezer собирает по тому,
  /// что слушают вместе. Точнее, чем список похожих исполнителей. Каждый раз немного новый — держим 30 минут
  Future<List<WebTrack>> radio(int id, {bool low = true}) async {
    final hit = _radio[id];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 30)) return hit.$2;
    final j = await _deezer('/artist/$id/radio', {'limit': '50'}, low);
    final list = [for (final x in (j['data'] as List? ?? const [])) if (x is Map) WebTrack.fromDeezer(x)];
    _radio[id] = (DateTime.now(), list);
    return list;
  }
  final Map<int, WebAlbum> _albumsById = {};

  /// Исполнитель по id Deezer (для страниц из поиска и «Похожих»)
  Future<WebArtist> artistById(int id) async {
    final hit = _artistsById[id];
    if (hit != null) return hit;
    return _artistsById[id] = WebArtist.fromDeezer(await _deezer('/artist/$id'));
  }

  /// Популярные треки исполнителя (до 50)
  Future<List<WebTrack>> top(int id) async {
    final hit = _top[id];
    if (hit != null) return hit;
    final j = await _deezer('/artist/$id/top', {'limit': '50'});
    return _top[id] = [for (final x in (j['data'] as List? ?? const [])) if (x is Map) WebTrack.fromDeezer(x)];
  }

  /// Похожие исполнители
  Future<List<WebArtist>> related(int id) async {
    final hit = _related[id];
    if (hit != null) return hit;
    final j = await _deezer('/artist/$id/related', {'limit': '30'});
    return _related[id] = [for (final x in (j['data'] as List? ?? const [])) if (x is Map) WebArtist.fromDeezer(x)];
  }

  /// Альбом целиком: сведения и треки
  Future<(WebAlbum, List<WebTrack>)> albumById(int id) async {
    final known = _albumsById[id];
    final cached = _tracks[id];
    if (known != null && cached != null) return (known, cached);
    final j = await _deezer('/album/$id');
    final album = WebAlbum.fromDeezer(j);
    final tracks = [
      for (final x in ((j['tracks'] as Map?)?['data'] as List? ?? const []))
        if (x is Map) WebTrack.fromDeezer(x, album: j)
    ];
    _albumsById[id] = album;
    _tracks[id] = tracks;
    return (album, tracks);
  }

  /// Поиск по Deezer: треки, альбомы и исполнители сразу
  Future<({List<WebTrack> tracks, List<WebAlbum> albums, List<WebArtist> artists})> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return (tracks: const <WebTrack>[], albums: const <WebAlbum>[], artists: const <WebArtist>[]);
    final r = await Future.wait([
      _deezer('/search/track', {'q': q, 'limit': '30'}),
      _deezer('/search/album', {'q': q, 'limit': '16'}),
      _deezer('/search/artist', {'q': q, 'limit': '12'}),
    ]);
    List<Map> data(Map j) => [for (final x in (j['data'] as List? ?? const [])) if (x is Map) x];
    return (
      tracks: [for (final x in data(r[0])) WebTrack.fromDeezer(x)],
      albums: [for (final x in data(r[1])) WebAlbum.fromDeezer(x)],
      artists: [for (final x in data(r[2])) WebArtist.fromDeezer(x)],
    );
  }

  // ---------- что уже есть в библиотеке ----------

  /// Альбом уже есть у вас: совпадает название альбома у этого исполнителя
  /// или (для синглов) есть такая песня
  bool inLibrary(String artistKey, WebAlbum a) {
    final mine = lib.artist(artistKey);
    if (mine == null) return false;
    final want = _normTitle(a.title);
    if (want.isEmpty) return false;
    for (final t in mine.tracks) {
      if (_normTitle(t.displayAlbum) == want) return true;
    }
    if (a.type == 'single' || a.type == 'ep') {
      for (final t in mine.tracks) {
        if (_normTitle(t.title) == want) return true;
      }
    }
    return false;
  }

  /// Песня уже есть в библиотеке
  bool trackInLibrary(WebTrack t) => lib.existing(t.artist, t.title) != null;

  // ---------- Википедия ----------

  static final _musicWords = RegExp(
    r'музык|певе[цч]|певиц|рэп|рок|групп|исполнител|композитор|диджей|продюсер|гитарист|'
    r'singer|band|musician|rapper|composer|record producer|\bdj\b|songwriter|duo|group',
    caseSensitive: false,
  );

  WebBio? bioCached(String name) {
    if (!_loaded) return null;
    return _fresh<WebBio?>('bio:${_key(name)}', _artistTtl, (v) => v is Map ? WebBio('${v['t']}', '${v['u']}') : null);
  }

  /// Короткое описание из Википедии (сначала русской). Берём, только если статья про музыканта
  Future<WebBio?> bio(String name) async {
    await _load();
    final key = 'bio:${_key(name)}';
    if (_isFresh(key, _artistTtl)) {
      final v = _value(key);
      return v is Map ? WebBio('${v['t']}', '${v['u']}') : null;
    }
    WebBio? found;
    for (final lang in const ['ru', 'en']) {
      try {
        final res = await _http
            .get(Uri.https('$lang.wikipedia.org', '/api/rest_v1/page/summary/${Uri.encodeComponent(name.replaceAll(' ', '_'))}'))
            .timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) continue;
        final j = jsonDecode(utf8.decode(res.bodyBytes));
        if (j is! Map || j['type'] != 'standard') continue;
        final desc = '${j['description'] ?? ''}';
        final text = '${j['extract'] ?? ''}'.trim();
        if (text.isEmpty || !_musicWords.hasMatch('$desc ${text.length > 300 ? text.substring(0, 300) : text}')) continue;
        final url = '${((j['content_urls'] as Map?)?['desktop'] as Map?)?['page'] ?? ''}';
        found = WebBio(text, url);
        break;
      } catch (_) {}
    }
    _put(key, found == null ? null : {'t': found.text, 'u': found.url});
    notifyListeners();
    return found;
  }

  // ---------- новинки ----------

  List<NewRelease> releases = const [];
  bool loadingReleases = false;
  int releasesDone = 0;
  int releasesTotal = 0;
  int releasesFailed = 0;
  String? releasesError;
  DateTime? releasesAt;
  bool _stop = false;

  /// Остановить проверку новинок (что успели найти — останется)
  void stopReleases() => _stop = true;

  /// Свежие (за [days] дней) альбомы и синглы исполнителей из библиотеки, которых у вас нет.
  /// Смотрим самых слушаемых в библиотеке исполнителей, не больше [maxArtists].
  Future<void> loadReleases({bool force = false, int days = 120, int maxArtists = 60}) async {
    if (loadingReleases) return;
    final at = releasesAt;
    if (!force && at != null && DateTime.now().difference(at) < const Duration(hours: 6)) return;
    loadingReleases = true;
    _stop = false;
    releasesError = null;
    releasesFailed = 0;
    releasesDone = 0;
    notifyListeners();
    try {
      await _load();
      final artists = List.of(lib.artists)
        ..removeWhere((a) => a.name == 'Неизвестный исполнитель')
        ..sort((a, b) => b.tracks.length.compareTo(a.tracks.length));
      final pick = artists.take(maxArtists).toList();
      releasesTotal = pick.length;
      notifyListeners();
      AppLog.info('Новинки: проверяю ${pick.length} исполнителей, ${queueState()}');
      // Сторож: если за 20 секунд никто не проверен — пишем в журнал, что творится с очередью
      Timer(const Duration(seconds: 20), () {
        if (loadingReleases && releasesDone == 0) AppLog.warn('Новинки: за 20 с ни одного исполнителя, ${queueState()}');
      });
      final since = DateTime.now().subtract(Duration(days: days));
      final out = <NewRelease>[];
      var i = 0;
      var failedInRow = 0;
      Future<void> worker() async {
        while (i < pick.length && !_stop && releasesError == null) {
          final a = pick[i++];
          try {
            // Один исполнитель — не дольше 30 секунд, что бы ни случилось
            await () async {
              final w = await _search(a.name, false);
              if (w == null) return;
              for (final al in await albums(w)) {
                final d = al.released;
                if (d == null || d.isBefore(since)) continue;
                if (!inLibrary(a.key, al)) out.add(NewRelease(a.key, al));
              }
            }()
                .timeout(const Duration(seconds: 30), onTimeout: () => throw TimeoutException('исполнитель ${a.name}: ${queueState()}'));
            failedInRow = 0;
          } catch (e) {
            releasesFailed++;
            failedInRow++;
            AppLog.warn('Новинки: ${a.name}', e);
            // Несколько ошибок подряд — Deezer недоступен, не ждём остальные таймауты
            if (failedInRow >= 4) releasesError = 'Deezer не отвечает: $e';
          }
          releasesDone++;
          // Показываем найденное по ходу, а не только в конце
          releases = _sorted(out);
          notifyListeners();
        }
      }

      await Future.wait([worker(), worker(), worker()]);
      releases = _sorted(out);
      // Проверили почти всех — помним результат 6 часов; иначе в следующий раз проверим снова
      if (releasesError == null && !_stop && releasesFailed <= releasesTotal ~/ 5) releasesAt = DateTime.now();
      AppLog.info('Новинки: проверено $releasesDone из $releasesTotal, ошибок $releasesFailed, найдено ${releases.length}'
          '${_stop ? ' (остановлено)' : ''}${releasesError != null ? ' — $releasesError' : ''}');
    } catch (e) {
      releasesError = '$e';
      AppLog.warn('Новинки', e);
    } finally {
      loadingReleases = false;
      notifyListeners();
    }
  }

  static List<NewRelease> _sorted(List<NewRelease> out) {
    final list = List.of(out)..sort((a, b) => b.album.date.compareTo(a.album.date));
    // Один релиз мог найтись у нескольких соавторов
    final seen = <int>{};
    return [for (final r in list) if (seen.add(r.album.id)) r];
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _http.close();
    super.dispose();
  }
}

/// Фоновый запрос отброшен из очереди (строку уже пролистали)
class _Dropped implements Exception {
  const _Dropped();
}

/// Deezer просит снизить частоту запросов
class _Quota implements Exception {
  const _Quota();
  @override
  String toString() => 'Deezer: слишком много запросов';
}
