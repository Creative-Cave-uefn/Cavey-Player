import 'dart:math' as math;

import 'web_info.dart';

// Порядок результатов поиска в интернете: сначала то, что человек, скорее всего, искал (популярные официальные релизы),
// а каверы, ремиксы, караоке и фанатские версии ниже. Deezer сам отдаёт «по релевантности», где такие версии часто выше оригинала.

/// Слова, по которым узнаём версии не от автора. Если слово есть и в самом запросе — человек искал именно это
const _noise = [
  'cover', 'covers', 'tribute', 'karaoke', 'remix', 'remixes', 'remixed', 'metal version', 'piano version', 'acoustic version',
  'orchestral version', 'lofi', 'lo-fi', 'lo fi', '8-bit', '8 bit', 'sped up', 'slowed', 'nightcore', 'reverb', 'bass boosted',
  'type beat', 'made famous by', 'in the style of', 'originally performed', 'instrumental version', 'music box', 'ukulele',
  'cover version', 'epic version', 'guitar version', 'rock version', 'trap version', 'chill version',
];

List<String> _words(String s) => [
      for (final w in s.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
        if (w.isNotEmpty) w
    ];

/// Сколько «чужих» признаков в названии: 0 — обычное название. Слова, которые есть в запросе, не считаются
int noiseCount(String text, String query) {
  final t = text.toLowerCase();
  final q = query.toLowerCase();
  var n = 0;
  for (final w in _noise) {
    if (t.contains(w) && !q.contains(w)) n++;
  }
  return n;
}

/// Доля слов запроса, которые есть в [text] (0…1)
double matchShare(String query, String text) {
  final q = _words(query);
  if (q.isEmpty) return 0;
  final t = _words(text).toSet();
  var hit = 0;
  for (final w in q) {
    if (t.contains(w) || t.any((x) => x.startsWith(w))) hit++;
  }
  return hit / q.length;
}

/// Альбомы: [byRelevance] — ответ Deezer по релевантности, [byRanking] — он же по популярности.
/// Треки и исполнители помогают оценить популярность и узнать автора
List<WebAlbum> rankAlbums(
  String query,
  List<WebAlbum> byRelevance,
  List<WebAlbum> byRanking, {
  List<WebTrack> tracks = const [],
  List<WebArtist> artists = const [],
}) {
  final all = <int, WebAlbum>{};
  for (final a in [...byRelevance, ...byRanking]) {
    all.putIfAbsent(a.id, () => a);
  }
  if (all.isEmpty) return const [];
  double byPos(List<WebAlbum> l, int id, double max) {
    final i = l.indexWhere((a) => a.id == id);
    return i < 0 || l.isEmpty ? 0 : max * (l.length - i) / l.length;
  }

  // Популярность треков, найденных по запросу, сводим по альбомам
  final trackPop = <int, double>{};
  for (final t in tracks) {
    if (t.albumId == 0) continue;
    trackPop[t.albumId] = math.max(trackPop[t.albumId] ?? 0, t.rank / 1e6);
  }
  final fans = <String, int>{
    for (final a in artists) a.name.toLowerCase(): a.fans,
  };
  double score(WebAlbum a) {
    var s = byPos(byRanking, a.id, 40) + byPos(byRelevance, a.id, 15);
    s += math.min(20.0, (trackPop[a.id] ?? 0) * 20);
    s += matchShare(query, '${a.title} ${a.artist}') * 25;
    s += switch (a.type) { 'album' || 'compile' => 6, 'ep' => 3, _ => 0 };
    s -= 35 * math.min(2, noiseCount('${a.title} ${a.artist}', query));
    final f = fans[a.artist.toLowerCase()];
    if (f != null && f > 0) s += math.log(f + 1) / math.ln10 * 3;
    return s;
  }

  final scored = [for (final a in all.values) (a, score(a))];
  // Устойчивая сортировка: при равных оценках остаётся порядок Deezer
  final order = {for (var i = 0; i < byRelevance.length; i++) byRelevance[i].id: i};
  scored.sort((x, y) {
    final c = y.$2.compareTo(x.$2);
    if (c != 0) return c;
    return (order[x.$1.id] ?? 1000).compareTo(order[y.$1.id] ?? 1000);
  });
  return [for (final e in scored) e.$1];
}

/// Треки: популярность (rank у Deezer), совпадение с запросом, каверы ниже
List<WebTrack> rankTracks(String query, List<WebTrack> tracks) {
  if (tracks.length < 2) return tracks;
  double score(WebTrack t) {
    var s = math.min(100.0, t.rank / 1e4);
    s += matchShare(query, '${t.title} ${t.artist} ${t.album}') * 20;
    s -= 40 * math.min(2, noiseCount('${t.title} ${t.artist} ${t.album}', query));
    return s;
  }

  final idx = {for (var i = 0; i < tracks.length; i++) tracks[i].id: i};
  final list = List.of(tracks);
  list.sort((a, b) {
    final c = score(b).compareTo(score(a));
    return c != 0 ? c : idx[a.id]!.compareTo(idx[b.id]!);
  });
  return list;
}

/// Исполнители: те, чьё имя совпало с запросом, выше; среди них больше подписчиков — выше
List<WebArtist> rankArtists(String query, List<WebArtist> artists) {
  if (artists.length < 2) return artists;
  double score(WebArtist a) => matchShare(query, a.name) * 100 + math.log(a.fans + 1) / math.ln10 * 5;
  final idx = {for (var i = 0; i < artists.length; i++) artists[i].id: i};
  final list = List.of(artists);
  list.sort((a, b) {
    final c = score(b).compareTo(score(a));
    return c != 0 ? c : idx[a.id]!.compareTo(idx[b.id]!);
  });
  return list;
}
