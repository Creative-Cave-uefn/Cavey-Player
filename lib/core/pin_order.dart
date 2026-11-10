// Закреплённые в коллекции: чистые функции порядка. Пункт — строка-«жетон» вида fp:<плейлист>, fl:<альбом>, fa:<исполнитель>.

class PinSplit<T> {
  final List<T> pinned;
  final List<T> rest;
  const PinSplit(this.pinned, this.rest);
}

/// Делит [items] на закреплённые (в порядке закрепа) и остальные (в прежнем порядке).
/// [tokens] — все жетоны пункта (у альбома их может быть несколько после склейки)
PinSplit<T> splitPinned<T>(List<T> items, Iterable<String> Function(T) tokens, List<String> pinned) {
  final order = <String, int>{for (var i = 0; i < pinned.length; i++) pinned[i]: i};
  final hit = <(int, T)>[];
  final rest = <T>[];
  for (final it in items) {
    int? at;
    for (final t in tokens(it)) {
      final i = order[t];
      if (i != null && (at == null || i < at)) at = i;
    }
    if (at == null) {
      rest.add(it);
    } else {
      hit.add((at, it));
    }
  }
  hit.sort((a, b) => a.$1.compareTo(b.$1));
  return PinSplit([for (final h in hit) h.$2], rest);
}

/// Перетащили [dragged] на место [target] в показанном списке «закреплённые, затем остальные».
/// [shown] — жетоны показанных пунктов в порядке показа, [pinnedShown] — сколько из них закреплено.
/// Возвращает новый порядок закреплённых среди показанных (null — ничего не меняется):
/// внутри закреплённых — просто перестановка; незакреплённый, брошенный в закреплённую зону, закрепляется;
/// закреплённый, брошенный ниже, открепляется.
List<String>? dropOnto(List<String> shown, int pinnedShown, String dragged, String target) {
  final from = shown.indexOf(dragged);
  final to = shown.indexOf(target);
  if (from < 0 || to < 0 || from == to) return null;
  final next = [...shown]
    ..removeAt(from)
    ..insert(to, dragged);
  final wasPinned = from < pinnedShown;
  final nowPinned = to < pinnedShown;
  if (!wasPinned && !nowPinned) return null; // порядок среди остальных не хранится
  final count = pinnedShown + (wasPinned == nowPinned ? 0 : (nowPinned ? 1 : -1));
  return next.take(count).toList();
}

/// Закрепы после перестановки: показанные — в новом порядке, а скрытые сейчас (например, выключен показ альбомов)
/// сохраняют свои места в конце
List<String> mergePins(List<String> allPinned, List<String> shownBefore, List<String> shownAfter) {
  final shownSet = shownBefore.toSet();
  final hidden = [for (final p in allPinned) if (!shownSet.contains(p)) p];
  return [...shownAfter, ...hidden];
}

/// Закрепить [token] (в конец закреплённых) или открепить
List<String> togglePin(List<String> pinned, String token) =>
    pinned.contains(token) ? [for (final p in pinned) if (p != token) p] : [...pinned, token];
