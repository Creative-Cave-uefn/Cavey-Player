// Яндекс Музыка и Spotify: по ссылке узнаём название, исполнителя, альбом,
// длительность и обложку. Сам звук потом ищется на YouTube.
// Перенесено из music_downloaderV2.py.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'text.dart';

const _browserHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'en-US,en;q=0.9',
};

final _client = http.Client();

Future<String> fetchText(String url, {Map<String, String>? headers}) async {
  final h = {'User-Agent': 'Mozilla/5.0', 'Accept-Language': 'en-US,en;q=0.9', ...?headers};
  Object? last;
  for (var i = 0; i < 3; i++) {
    final res = await _client.get(Uri.parse(url), headers: h).timeout(const Duration(seconds: 20));
    if (res.statusCode == 200) return utf8.decode(res.bodyBytes, allowMalformed: true);
    last = 'HTTP ${res.statusCode}';
    if (res.statusCode < 500) break;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
  }
  throw Exception('не удалось открыть $url ($last)');
}

// ---------- Яндекс Музыка ----------

String? _yandexCover(Map? obj) {
  if (obj == null) return null;
  final uri = (obj['coverUri'] ?? obj['ogImage']) as String?;
  if (uri == null || uri.isEmpty) return null;
  final u = uri.replaceAll('%%', '1000x1000');
  return u.startsWith('http') ? u : 'https://$u';
}

TrackMeta _yandexMeta(Map track, {Map? album, int? number, int? total}) {
  var title = '${track['title'] ?? ''}';
  if ((track['version'] ?? '').toString().isNotEmpty) title += ' (${track['version']})';
  final artists = [for (final a in (track['artists'] as List? ?? const [])) if (a is Map) '${a['name']}'];
  var alb = album;
  if (alb == null && track['albums'] is List && (track['albums'] as List).isNotEmpty) {
    alb = (track['albums'] as List).first as Map;
  }
  alb ??= const {};
  number ??= ((alb['trackPosition'] as Map?)?['index'] as num?)?.toInt();
  final year = '${alb['year'] ?? ''}'.isNotEmpty ? '${alb['year']}' : '${alb['releaseDate'] ?? ''}'.padRight(4).substring(0, 4).trim();
  final albumArtists = [for (final a in (alb['artists'] as List? ?? const [])) if (a is Map) '${a['name']}'];
  final ms = (track['durationMs'] as num?)?.toDouble() ?? 0;
  return TrackMeta(
    artist: artists.isNotEmpty ? artists.first : '',
    artistTag: artists.join(', '),
    albumArtist: albumArtists.isNotEmpty ? albumArtists.first : '',
    title: title,
    album: '${alb['title'] ?? ''}',
    year: year == 'null' ? '' : year,
    track: number != null && total != null ? '$number/$total' : (number?.toString() ?? ''),
    duration: ms > 0 ? ms / 1000 : null,
    coverUrl: _yandexCover(track) ?? _yandexCover(alb),
  );
}

Future<TrackMeta?> yandexTrack(String url) async {
  final m = RegExp(r'/track/(\d+)').firstMatch(url);
  if (m == null) return null;
  final data = jsonDecode(await fetchText('https://api.music.yandex.net/tracks/${m.group(1)}')) as Map;
  return _yandexMeta((data['result'] as List).first as Map);
}

Future<(String, List<TrackMeta>)?> yandexAlbum(String url) async {
  final m = RegExp(r'/album/(\d+)').firstMatch(url);
  if (m == null) return null;
  final data = jsonDecode(await fetchText('https://api.music.yandex.net/albums/${m.group(1)}/with-tracks')) as Map;
  final res = data['result'] as Map;
  final tracks = [for (final vol in (res['volumes'] as List)) for (final t in (vol as List)) t as Map];
  final metas = [for (var i = 0; i < tracks.length; i++) _yandexMeta(tracks[i], album: res, number: i + 1, total: tracks.length)];
  final artists = res['artists'] as List?;
  final artist = artists != null && artists.isNotEmpty ? '${(artists.first as Map)['name']}' : '';
  return ('$artist - ${res['title']}'.replaceAll(RegExp(r'^[ \-]+|[ \-]+$'), ''), metas);
}

/// Плейлист из внешнего сервиса: название, обложка и треки по порядку
class PlaylistInfo {
  final String name;
  final String? coverUrl;
  final List<TrackMeta> metas;

  /// Сервис отдал не весь плейлист (у Spotify без ключа это первые 100 треков)
  final bool truncated;
  const PlaylistInfo(this.name, this.coverUrl, this.metas, {this.truncated = false});
}

/// Лимит треков, которые Spotify отдаёт открытой странице плейлиста
const spotifyPlaylistLimit = 100;

/// Ссылка на плейлист Яндекс Музыки: старого вида (/users/<логин>/playlists/<номер>) или нового (/playlists/<код>)
String? yandexPlaylistApiUrl(String url) {
  final old = RegExp(r'/users/([^/?#]+)/playlists/(\d+)').firstMatch(url);
  if (old != null) return 'https://api.music.yandex.net/users/${old.group(1)}/playlists/${old.group(2)}';
  final nw = RegExp(r'/playlists/([A-Za-z0-9\-.]+)').firstMatch(url);
  if (nw != null) return 'https://api.music.yandex.net/playlist/${nw.group(1)}';
  return null;
}

Future<PlaylistInfo?> yandexPlaylist(String url) async {
  final api = yandexPlaylistApiUrl(url);
  if (api == null) return null;
  final data = jsonDecode(await fetchText(api)) as Map;
  final res = data['result'] as Map?;
  if (res == null) return null;
  final entries = [for (final e in (res['tracks'] as List? ?? const [])) if (e is Map) e];
  final tracks = <Map>[];
  final missing = <String>[];
  for (final e in entries) {
    final t = e['track'];
    if (t is Map) {
      tracks.add(t);
    } else if (e['id'] != null) {
      missing.add('${e['id']}${e['albumId'] != null ? ':${e['albumId']}' : ''}');
    }
  }
  // Короткий ответ без самих треков: дозапрашиваем пачками
  for (var i = 0; i < missing.length; i += 100) {
    final chunk = missing.sublist(i, i + 100 > missing.length ? missing.length : i + 100);
    try {
      final more = jsonDecode(await fetchText('https://api.music.yandex.net/tracks?track-ids=${chunk.join(',')}')) as Map;
      for (final t in (more['result'] as List? ?? const [])) {
        if (t is Map) tracks.add(t);
      }
    } catch (_) {}
  }
  final metas = [for (final t in tracks) _yandexMeta(t)];
  if (metas.isEmpty) return null;
  var cover = _yandexCover(res);
  if (cover == null && res['cover'] is Map) {
    final u = '${(res['cover'] as Map)['uri'] ?? ''}';
    if (u.isNotEmpty) {
      final big = u.replaceAll('%%', '1000x1000');
      cover = big.startsWith('http') ? big : 'https://$big';
    }
  }
  return PlaylistInfo('${res['title'] ?? 'Плейлист'}', cover, metas);
}

// ---------- Deezer ----------
// Открытый API без ключа: трек и альбом целиком, с номерами, годом и обложкой

TrackMeta _deezerMeta(Map t, {Map? album, int? number, int? total}) {
  final alb = album ?? (t['album'] as Map?) ?? const {};
  final contributors = [for (final c in (t['contributors'] as List? ?? const [])) if (c is Map) '${c['name']}'];
  final main = '${(t['artist'] as Map?)?['name'] ?? ''}';
  final date = '${t['release_date'] ?? alb['release_date'] ?? ''}';
  final n = number ?? (t['track_position'] as num?)?.toInt();
  return TrackMeta(
    artist: main,
    artistTag: contributors.length > 1 ? contributors.join(', ') : main,
    albumArtist: '${(alb['artist'] as Map?)?['name'] ?? main}',
    title: '${t['title'] ?? ''}',
    album: '${alb['title'] ?? ''}',
    year: date.length >= 4 ? date.substring(0, 4) : '',
    track: n != null && total != null ? '$n/$total' : (n?.toString() ?? ''),
    duration: (t['duration'] as num?)?.toDouble(),
    coverUrl: (alb['cover_xl'] ?? alb['cover_big']) as String?,
  );
}

Future<TrackMeta?> deezerTrack(String url) async {
  final m = RegExp(r'/track/(\d+)').firstMatch(url);
  if (m == null) return null;
  final t = jsonDecode(await fetchText('https://api.deezer.com/track/${m.group(1)}')) as Map;
  if (t['error'] != null) return null;
  return _deezerMeta(t);
}

/// Версии, которые не нужны, если о них не просили
const _otherVersion = ['live', 'remix', 'acoustic', 'instrumental', 'karaoke', 'cover', 'sped up', 'slowed', 'demo', 'concert'];

/// Лучший трек Deezer для подходящего результата поиска: та же песня и тот же исполнитель, без «live» и ремиксов,
/// если их нет в запросе. null — уверенного совпадения нет
int? pickDeezer(List<Map> results, String artist, String title, String query) {
  final want = normTitle(title);
  final who = normTitle(artist);
  final q = query.toLowerCase();
  for (final t in results) {
    final name = '${t['title'] ?? ''}';
    final got = normTitle(name);
    if (want.isEmpty || got.isEmpty) continue;
    if (!(got == want || got.startsWith('$want ') || want.startsWith('$got '))) continue;
    if (who.isNotEmpty) {
      final a = normTitle('${(t['artist'] as Map?)?['name'] ?? ''}');
      if (!(a == who || a.contains(who) || who.contains(a))) continue;
    }
    final low = '$name ${(t['title_version'] ?? '')}'.toLowerCase();
    if (_otherVersion.any((w) => hasWord(low, w) && !hasWord(q, w))) continue;
    final id = (t['id'] as num?)?.toInt();
    if (id != null) return id;
  }
  return null;
}

/// Текст «Исполнитель - Название» → трек Deezer: длительность, альбом, год и обложка.
/// По длительности потом выбирается студийная запись на YouTube, а не клип или концерт
Future<TrackMeta?> deezerFind(String text) async {
  final (artist, title) = text.contains(' - ') ? splitArtistTitle('', text) : ('', text);
  final t = title.isEmpty ? text : title;
  Future<List<Map>> search(String q) async {
    final data = jsonDecode(await fetchText('https://api.deezer.com/search?limit=15&q=${Uri.encodeQueryComponent(q)}'));
    return [for (final x in ((data as Map)['data'] as List? ?? const [])) if (x is Map) x];
  }

  var id = artist.isEmpty ? null : pickDeezer(await search('artist:"$artist" track:"$t"'), artist, t, text);
  id ??= pickDeezer(await search(text), artist, t, text);
  if (id == null) return null;
  return deezerTrack('https://www.deezer.com/track/$id');
}

Future<(String, List<TrackMeta>)?> deezerAlbum(String url) async {
  final m = RegExp(r'/album/(\d+)').firstMatch(url);
  if (m == null) return null;
  final a = jsonDecode(await fetchText('https://api.deezer.com/album/${m.group(1)}')) as Map;
  if (a['error'] != null) return null;
  final tracks = [for (final t in ((a['tracks'] as Map?)?['data'] as List? ?? const [])) if (t is Map) t];
  final metas = [for (var i = 0; i < tracks.length; i++) _deezerMeta(tracks[i], album: a, number: i + 1, total: tracks.length)];
  final artist = '${(a['artist'] as Map?)?['name'] ?? ''}';
  return ('$artist - ${a['title']}'.replaceAll(RegExp(r'^[ \-]+|[ \-]+$'), ''), metas);
}

// ---------- Spotify ----------

const _genericMarkers = ['spotify is all the music', 'listening is everything', 'web player', 'music for everyone'];

/// Заглушка Spotify вместо настоящего названия
bool looksGeneric(String? text) {
  final t = (text ?? '').toLowerCase().trim();
  return t.isEmpty || t == 'spotify' || _genericMarkers.any(t.contains);
}

Iterable<Object?> _walk(Object? obj) sync* {
  yield obj;
  if (obj is Map) {
    for (final v in obj.values) {
      yield* _walk(v);
    }
  } else if (obj is List) {
    for (final v in obj) {
      yield* _walk(v);
    }
  }
}

Future<List<Object?>> _embedBlobs(String kind, String id) async {
  final page = await fetchText('https://open.spotify.com/embed/$kind/$id', headers: _browserHeaders);
  final blobs = <Object?>[];
  for (final m in RegExp(r'<script[^>]*type="application/json"[^>]*>(.*?)</script>', dotAll: true).allMatches(page)) {
    try {
      blobs.add(jsonDecode(m.group(1)!));
    } catch (_) {}
  }
  if (blobs.isEmpty) throw Exception('на странице Spotify нет данных');
  return blobs;
}

double? _seconds(Object? v) {
  if (v is num && v > 0) return v > 10000 ? v / 1000 : v.toDouble();
  return null;
}

String _yearOf(Object? v) {
  var x = v;
  if (x is Map) x = x['isoString'] ?? x['year'] ?? '';
  return RegExp(r'^\d{4}').firstMatch('${x ?? ''}')?.group(0) ?? '';
}

String? _findCover(Object? obj) {
  String? best;
  var bestW = -1;
  for (final d in _walk(obj)) {
    if (d is Map && d['sources'] is List) {
      for (final s in d['sources'] as List) {
        if (s is Map && s['url'] != null) {
          final w = ((s['width'] ?? s['maxWidth'] ?? 0) as num).toInt();
          if (w >= bestW) {
            best = '${s['url']}';
            bestW = w;
          }
        }
      }
    }
  }
  return best;
}

String? _entityCover(Map e) {
  String? best;
  var bestW = -1;
  for (final sources in [(e['coverArt'] as Map?)?['sources'], (e['visualIdentity'] as Map?)?['image']]) {
    for (final s in (sources as List? ?? const [])) {
      if (s is! Map || s['url'] == null) continue;
      final w = ((s['width'] ?? s['maxWidth'] ?? 0) as num).toInt();
      if (w >= bestW) {
        best = '${s['url']}';
        bestW = w;
      }
    }
  }
  return best;
}

bool _isTrackEntity(Map d) {
  final name = d['name'] ?? d['title'];
  if (name is! String || name.trim().isEmpty) return false;
  final uri = '${d['uri'] ?? ''}';
  final artists = d['artists'];
  final hasArtists = artists is List && artists.any((a) => a is Map && a['name'] != null);
  final hasDuration = d.containsKey('duration') || d.containsKey('durationMs') || d.containsKey('duration_ms');
  return (uri.startsWith('spotify:track:') || hasDuration) && (hasArtists || d['subtitle'] is String);
}

Future<TrackMeta?> _spotifyTrackFromEmbed(String id) async {
  Map? entity;
  for (final blob in await _embedBlobs('track', id)) {
    for (final d in _walk(blob)) {
      if (d is Map && _isTrackEntity(d)) {
        entity = d;
        break;
      }
    }
    if (entity != null) break;
  }
  if (entity == null) throw Exception('не нашёл данные трека на странице Spotify');
  final title = '${entity['name'] ?? entity['title'] ?? ''}'.trim();
  var artists = [
    for (final a in (entity['artists'] as List? ?? const []))
      if (a is Map && a['name'] != null) '${a['name']}'.trim()
  ];
  if (artists.isEmpty) {
    artists = '${entity['subtitle'] ?? ''}'.replaceAll(' ', ' ').split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
  }
  if (title.isEmpty || artists.isEmpty) return null;
  return TrackMeta(
    artist: artists.first,
    artistTag: artists.join(', '),
    title: title,
    year: _yearOf(entity['releaseDate']),
    duration: _seconds(entity['duration'] ?? entity['durationMs'] ?? entity['duration_ms']),
    coverUrl: _entityCover(entity) ?? _findCover(entity),
  );
}

String? _metaTag(String page, String prop) {
  for (final p in [
    '<meta[^>]+(?:property|name)="${RegExp.escape(prop)}"[^>]+content="([^"]*)"',
    '<meta[^>]+content="([^"]*)"[^>]+(?:property|name)="${RegExp.escape(prop)}"',
  ]) {
    final m = RegExp(p).firstMatch(page);
    if (m != null) return _unescape(m.group(1)!).trim();
  }
  return null;
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');

Future<TrackMeta?> _spotifyTrackFromPage(String id) async {
  final page = await fetchText('https://open.spotify.com/track/$id', headers: _browserHeaders);
  String? title, artist;
  final t = RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(page);
  if (t != null) {
    final mt = RegExp(r'(.+?) - song(?: and lyrics)? by (.+?) \| Spotify$').firstMatch(_unescape(t.group(1)!).trim());
    if (mt != null) {
      title = mt.group(1)!.trim();
      artist = mt.group(2)!.trim();
    }
  }
  final parts = (_metaTag(page, 'og:description') ?? '').split('·').map((p) => p.trim()).toList();
  if (title == null) {
    title = _metaTag(page, 'og:title');
    artist = parts.firstWhere(
        (p) => p.isNotEmpty && p.toLowerCase() != 'song' && p.toLowerCase() != 'track' && int.tryParse(p) == null && !p.toLowerCase().startsWith('listen'),
        orElse: () => '');
  }
  if (title == null || title.isEmpty || artist == null || artist.isEmpty) return null;
  var album = '', year = '';
  if (parts.length >= 4 && parts[2].toLowerCase() == 'song') album = parts[1];
  if (parts.isNotEmpty && RegExp(r'^\d{4}$').hasMatch(parts.last)) year = parts.last;
  final dur = _metaTag(page, 'music:duration');
  return TrackMeta(
    artist: artist.split(',').first.trim(),
    artistTag: artist,
    title: title,
    album: album,
    year: year,
    duration: dur != null ? double.tryParse(dur) : null,
    coverUrl: _metaTag(page, 'og:image'),
  );
}

Future<TrackMeta?> spotifyTrack(String url, void Function(String) log) async {
  final m = RegExp(r'(?:/track/|spotify:track:)([A-Za-z0-9]+)').firstMatch(url);
  if (m == null) return null;
  for (final getter in [_spotifyTrackFromEmbed, _spotifyTrackFromPage]) {
    try {
      final meta = await getter(m.group(1)!);
      if (meta != null && !looksGeneric(meta.title) && !looksGeneric(meta.artist)) return meta;
    } catch (e) {
      log('Spotify: не получилось одним способом ($e), пробую другой…');
    }
  }
  return null;
}

Future<(String, List<TrackMeta>)?> spotifyAlbum(String url) async {
  final m = RegExp(r'(?:/album/|spotify:album:)([A-Za-z0-9]+)').firstMatch(url);
  if (m == null) return null;
  Map? entity;
  for (final blob in await _embedBlobs('album', m.group(1)!)) {
    for (final d in _walk(blob)) {
      if (d is Map && d['trackList'] is List && (d['trackList'] as List).isNotEmpty) {
        entity = d;
        break;
      }
    }
    if (entity != null) break;
  }
  if (entity == null) throw Exception('не нашёл список треков альбома на странице Spotify');
  final albumTitle = '${entity['name'] ?? entity['title'] ?? 'Album'}';
  final albumArtist = '${entity['subtitle'] ?? ''}'.replaceAll(' ', ' ');
  final cover = _entityCover(entity) ?? _findCover(entity);
  final year = _yearOf(entity['releaseDate']);
  final raw = [
    for (final t in entity['trackList'] as List)
      if (t is Map && '${t['title'] ?? t['name'] ?? ''}'.trim().isNotEmpty) t
  ];
  if (raw.isEmpty) throw Exception('список треков альбома пуст');
  final metas = <TrackMeta>[];
  for (var i = 0; i < raw.length; i++) {
    final t = raw[i];
    final artist = '${t['subtitle'] ?? albumArtist}'.replaceAll(' ', ' ');
    metas.add(TrackMeta(
      artist: artist.split(',').first.trim(),
      artistTag: artist,
      albumArtist: albumArtist.split(',').first.trim(),
      title: '${t['title'] ?? t['name']}'.trim(),
      album: albumTitle,
      year: year,
      track: '${i + 1}/${raw.length}',
      duration: _seconds(t['duration'] ?? t['durationMs']),
      coverUrl: cover,
    ));
  }
  return ('${albumArtist.split(',').first.trim()} - $albumTitle'.replaceAll(RegExp(r'^[ \-]+|[ \-]+$'), ''), metas);
}

/// Плейлист Spotify по открытой странице. Без ключа Spotify отдаёт первые [spotifyPlaylistLimit] треков.
Future<PlaylistInfo?> spotifyPlaylist(String url) async {
  final m = RegExp(r'(?:/playlist/|spotify:playlist:)([A-Za-z0-9]+)').firstMatch(url);
  if (m == null) return null;
  Map? entity;
  for (final blob in await _embedBlobs('playlist', m.group(1)!)) {
    for (final d in _walk(blob)) {
      if (d is Map && d['trackList'] is List && (d['trackList'] as List).isNotEmpty) {
        entity = d;
        break;
      }
    }
    if (entity != null) break;
  }
  if (entity == null) throw Exception('не нашёл список треков плейлиста на странице Spotify (возможно, он закрытый)');
  final name = '${entity['name'] ?? entity['title'] ?? 'Плейлист'}'.trim();
  final raw = [
    for (final t in entity['trackList'] as List)
      if (t is Map && '${t['title'] ?? t['name'] ?? ''}'.trim().isNotEmpty) t
  ];
  if (raw.isEmpty) throw Exception('список треков плейлиста пуст');
  final metas = <TrackMeta>[];
  for (final t in raw) {
    final artist = '${t['subtitle'] ?? ''}'.replaceAll('\u00a0', ' ').trim();
    metas.add(TrackMeta(
      artist: artist.split(',').first.trim(),
      artistTag: artist,
      title: '${t['title'] ?? t['name']}'.trim(),
      duration: _seconds(t['duration'] ?? t['durationMs']),
    ));
  }
  return PlaylistInfo(name, _entityCover(entity) ?? _findCover(entity), metas, truncated: raw.length >= spotifyPlaylistLimit);
}
