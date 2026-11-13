import 'library.dart';
import 'web_info.dart';

/// Итог сортировки альбома по Deezer
enum DeezerSort { done, alreadySorted, notFound }

/// Ставит треки альбома в порядок, который выдаёт Deezer (диски идут подряд, нумерация продолжается).
/// Треки, которых в Deezer нет, встают в конец в прежнем порядке. Порядок общий для всех друзей
Future<DeezerSort> sortAlbumByDeezer(LibraryController lib, WebInfoService web, Album a) async {
  final names = [if (a.artist != 'Разные исполнители') a.artist, ...a.artists.where((n) => n != a.artist)];
  final found = await web.findAlbum(a.title, names, haveTitles: [for (final t in a.tracks) t.title]);
  if (found == null) return DeezerSort.notFound;
  final remote = await web.albumTracks(found.id);
  if (remote.isEmpty) return DeezerSort.notFound;
  final order = deezerOrder([for (final t in a.tracks) (t.id, t.title)], [for (final t in remote) t.title]);
  final now = [for (final t in a.tracks) t.id];
  if (order.length == now.length && [for (var i = 0; i < now.length; i++) now[i] == order[i]].every((x) => x)) {
    return DeezerSort.alreadySorted;
  }
  lib.setMeta({'ao:${a.key}': {'o': order.join(',')}}, label: 'Порядок треков «${a.title}»');
  return DeezerSort.done;
}

/// Порядок id: сначала треки, найденные в списке Deezer (по его порядку), затем остальные как были.
/// [mine] — (id, название) в текущем порядке; [remote] — названия в порядке Deezer
List<String> deezerOrder(List<(String, String)> mine, List<String> remote) {
  final rank = <String, List<int>>{};
  for (final (i, title) in remote.indexed) {
    rank.putIfAbsent(WebInfoService.trackTitleKey(title), () => []).add(i);
  }
  final used = <int>{};
  final placed = <(String, int)>[];
  final rest = <String>[];
  for (final (id, title) in mine) {
    final slots = rank[WebInfoService.trackTitleKey(title)];
    final slot = slots?.where((i) => !used.contains(i)).firstOrNull;
    if (slot == null) {
      rest.add(id);
    } else {
      used.add(slot);
      placed.add((id, slot));
    }
  }
  placed.sort((x, y) => x.$2.compareTo(y.$2));
  return [for (final p in placed) p.$1, ...rest];
}
