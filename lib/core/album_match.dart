import 'library.dart';
import 'models.dart';
import 'web_info.dart';

/// Какие треки альбома из интернета ещё не скачаны (подробности — в missingAlbumTracks).
List<WebTrack> missingByMatch(List<Track> own, List<WebTrack> web, {bool Function(WebTrack)? inLibrary}) {
  final taken = <int>{}; // индексы ваших треков, которые уже засчитаны
  final matched = <int>{}; // индексы треков из интернета, которые нашлись
  int? sec(Track t) => t.durationMs == null || t.durationMs! <= 0 ? null : (t.durationMs! / 1000).round();

  // Номер трека внутри своего диска у треков из интернета: по порядку в альбоме
  final perDisc = <int, int>{};
  final webNo = <int>[
    for (final w in web) perDisc[w.disc] = (perDisc[w.disc] ?? 0) + 1,
  ];

  // 1. По названию
  for (var i = 0; i < web.length; i++) {
    final key = WebInfoService.trackTitleKey(web[i].title);
    for (var j = 0; j < own.length; j++) {
      if (taken.contains(j)) continue;
      if (WebInfoService.trackTitleKey(own[j].title) == key) {
        taken.add(j);
        matched.add(i);
        break;
      }
    }
  }

  // 2. По номеру диска и трека и длительности
  for (var i = 0; i < web.length; i++) {
    if (matched.contains(i)) continue;
    for (var j = 0; j < own.length; j++) {
      if (taken.contains(j)) continue;
      final t = own[j];
      if (t.no == null || t.no != webNo[i] || discOf(t) != web[i].disc) continue;
      final d = sec(t);
      // Длительность не известна ни тут, ни там — довольствуемся совпадением номера
      if (d == null || web[i].seconds <= 0 || (d - web[i].seconds).abs() <= 3) {
        taken.add(j);
        matched.add(i);
        break;
      }
    }
  }

  // 3. По одной длительности: ближайший из ещё свободных
  for (var i = 0; i < web.length; i++) {
    if (matched.contains(i) || web[i].seconds <= 0) continue;
    int? best;
    var bestDiff = 3;
    for (var j = 0; j < own.length; j++) {
      if (taken.contains(j)) continue;
      final d = sec(own[j]);
      if (d == null) continue;
      final diff = (d - web[i].seconds).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = j;
      }
    }
    if (best != null) {
      taken.add(best);
      matched.add(i);
    }
  }

  return [
    for (var i = 0; i < web.length; i++)
      if (!matched.contains(i) && !(inLibrary?.call(web[i]) ?? false)) web[i]
  ];
}
