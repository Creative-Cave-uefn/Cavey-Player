// Теги треков: личная библиотека тегов каждого человека.
// Хранятся в его личной записи общей библиотеки (edits['u:<почта>']), как любимые исполнители и закрепы,
// поэтому одинаковы на всех его компьютерах:
//   tg:<id тега>    → имя тега (пусто — тег удалён)
//   tt:<id трека>   → «<id тега>:<когда повесили, мс>,…»
// Связь по id тега, а не по имени: переименование ничего не теряет.

import 'dart:math';

import 'library.dart';
import 'models.dart';

const kTagMaxLen = 32;

final _sep = RegExp(r'[\s,#|]+');

/// Имя тега из ввода: строчными буквами, без пробелов, «#», запятых и «|»; не начинается с «-»
String cleanTagName(String raw) {
  var s = raw.trim().toLowerCase().replaceAll(_sep, '').replaceFirst(RegExp(r'^-+'), '');
  if (s.length > kTagMaxLen) s = s.substring(0, kTagMaxLen);
  return s;
}

/// Несколько тегов из строки: пробел и запятая разделяют теги («рок вечер #джаз» — три тега)
List<String> splitTagNames(String raw) {
  final out = <String>[];
  for (final part in raw.split(_sep)) {
    final n = cleanTagName(part);
    if (n.isNotEmpty && !out.contains(n)) out.add(n);
  }
  return out;
}

class TagInfo {
  final String id;
  final String name;
  const TagInfo(this.id, this.name);
}

/// Теги одного человека, разобранные из его личной записи. Строится заново при каждой правке библиотеки
class TagBook {
  final String owner;
  final Map<String, String> _names = {};
  final Map<String, String> _idByName = {};

  /// Одинаковое имя у двух id (теги, созданные одновременно на двух устройствах): id → главный id
  final Map<String, String> _alias = {};
  final Map<String, List<String>> _group = {};

  /// Трек (после склейки дубликатов) → {тег: когда повесили}
  final Map<String, Map<String, int>> _byTrack = {};

  /// Под какими id трека лежат записи (после склейки дубликатов их может быть несколько)
  final Map<String, List<String>> _raw = {};
  Map<String, List<(String, int)>>? _inverse;
  Map<String, int>? _counts;

  TagBook(this.owner, Map<String, String>? e, String Function(String) resolve) {
    if (e == null || e.isEmpty) return;
    final ids = <String>[];
    for (final en in e.entries) {
      if (!en.key.startsWith('tg:') || en.value.isEmpty) continue;
      final n = cleanTagName(en.value);
      if (n.isEmpty) continue;
      final id = en.key.substring(3);
      _names[id] = n;
      ids.add(id);
    }
    ids.sort();
    for (final id in ids) {
      final n = _names[id]!;
      final main = _idByName.putIfAbsent(n, () => id);
      if (main != id) _alias[id] = main;
      (_group[main] ??= []).add(id);
    }
    for (final en in e.entries) {
      if (!en.key.startsWith('tt:') || en.value.isEmpty) continue;
      final raw = en.key.substring(3);
      final id = resolve(raw);
      for (final part in en.value.split(',')) {
        if (part.isEmpty) continue;
        final i = part.indexOf(':');
        final tid = i < 0 ? part : part.substring(0, i);
        final ms = i < 0 ? 0 : (int.tryParse(part.substring(i + 1)) ?? 0);
        final main = _alias[tid] ?? tid;
        if (!_names.containsKey(main)) continue; // тег удалён
        final m = _byTrack.putIfAbsent(id, () => {});
        if (ms > (m[main] ?? -1)) m[main] = ms;
      }
      (_raw[id] ??= []).add(raw);
    }
  }

  /// Тегов нет совсем
  bool get isEmpty => _idByName.isEmpty;

  /// Все теги по алфавиту
  List<TagInfo> get all {
    final out = [for (final en in _idByName.entries) TagInfo(en.value, en.key)];
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  String? nameOf(String id) => _names[_alias[id] ?? id];
  String? idOfName(String name) => _idByName[name];
  bool exists(String id) => _idByName.containsValue(_alias[id] ?? id);

  /// Все id, которые значат один тег (главный и дубли)
  List<String> groupOf(String id) => _group[_alias[id] ?? id] ?? [id];

  /// Теги трека: сначала те, что повесили раньше
  List<String> tagsOf(String trackId) {
    final m = _byTrack[trackId];
    if (m == null || m.isEmpty) return const [];
    final ids = m.keys.toList()
      ..sort((a, b) {
        final r = m[a]!.compareTo(m[b]!);
        return r != 0 ? r : (_names[a] ?? '').compareTo(_names[b] ?? '');
      });
    return ids;
  }

  Map<String, int> timesOf(String trackId) => _byTrack[trackId] ?? const {};
  bool has(String trackId, String tagId) => _byTrack[trackId]?.containsKey(tagId) ?? false;
  List<String> rawKeysOf(String trackId) => _raw[trackId] ?? const [];

  /// Треки тега с датой, когда его повесили
  List<(String, int)> tracksOf(String tagId) => (_inverse ??= _buildInverse())[tagId] ?? const [];

  Map<String, List<(String, int)>> _buildInverse() {
    final inv = <String, List<(String, int)>>{};
    for (final t in _byTrack.entries) {
      for (final g in t.value.entries) {
        (inv[g.key] ??= []).add((t.key, g.value));
      }
    }
    return inv;
  }

  /// Сколько существующих треков у тега
  int count(String tagId, bool Function(String trackId) exists) {
    final c = _counts ??= {};
    return c[tagId] ??= tracksOf(tagId).where((e) => exists(e.$1)).length;
  }
}

/// Жетон закрепа тега (в общем списке закреплённого рядом с плейлистами, альбомами и исполнителями)
String tagPinToken(String id) => 'tag:$id';

/// Тег в ссылке и уведомлении: почта владельца и id тега
String tagShareKey(String owner, String id) => '$owner|$id';

/// Разбор ключа тега: «почта|id» или просто «id» (свой тег)
({String owner, String id}) parseTagKey(String key, String? me) {
  final i = key.lastIndexOf('|');
  if (i < 0) return (owner: me ?? '', id: key);
  return (owner: key.substring(0, i), id: key.substring(i + 1));
}

final _books = Expando<Map<String, (int, TagBook)>>('trackTagBooks');
final _rnd = Random();

extension TrackTagsOnLibrary on LibraryController {
  /// Теги этого человека (кэш живёт до следующей правки библиотеки)
  TagBook tagBookOf(String email) {
    final cache = (_books[this] ??= {});
    final hit = cache[email];
    if (hit != null && hit.$1 == revision) return hit.$2;
    final book = TagBook(email, data.edits['u:$email'], data.resolve);
    cache[email] = (revision, book);
    return book;
  }

  /// Мои теги
  TagBook get myTags => tagBookOf(me ?? '');

  static String _newTagId() => 'g${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rnd.nextInt(1 << 16).toRadixString(36)}';

  /// Находит или создаёт теги с такими именами; id в том же порядке (дубликаты имён схлопываются)
  List<String> ensureTags(Iterable<String> names) {
    final m = me;
    if (m == null) return const [];
    final book = myTags;
    final ids = <String>[];
    final fresh = <String, String>{};
    final byName = <String, String>{};
    for (final raw in names) {
      final n = cleanTagName(raw);
      if (n.isEmpty) continue;
      final id = book.idOfName(n) ?? byName[n];
      if (id != null) {
        if (!ids.contains(id)) ids.add(id);
        continue;
      }
      final nid = _newTagId();
      byName[n] = nid;
      fresh['tg:$nid'] = n;
      ids.add(nid);
    }
    if (fresh.isNotEmpty) setMeta({'u:$m': fresh});
    return ids;
  }

  /// Повесить или снять теги ([changes]: id тега → вешать) сразу у нескольких треков одной правкой
  void setTagsOn(Iterable<String> trackIds, Map<String, bool> changes) {
    final m = me;
    if (m == null || changes.isEmpty) return;
    final book = myTags;
    final now = DateTime.now().millisecondsSinceEpoch;
    final fields = <String, String>{};
    for (final id in trackIds) {
      final cur = Map<String, int>.of(book.timesOf(id));
      var changed = false;
      changes.forEach((tag, on) {
        if (on) {
          if (!cur.containsKey(tag)) {
            cur[tag] = now;
            changed = true;
          }
        } else if (cur.remove(tag) != null) {
          changed = true;
        }
      });
      if (!changed) continue;
      fields['tt:$id'] = [for (final e in cur.entries) '${e.key}:${e.value}'].join(',');
      // Записи под старыми id склеенных дубликатов убираем: иначе снятый тег вернулся бы
      for (final raw in book.rawKeysOf(id)) {
        if (raw != id) fields['tt:$raw'] = '';
      }
    }
    if (fields.isNotEmpty) setMeta({'u:$m': fields});
  }

  /// null — переименовано, иначе причина отказа для показа человеку
  String? renameTag(String id, String raw) {
    final m = me;
    if (m == null) return 'Нет входа в библиотеку';
    final n = cleanTagName(raw);
    if (n.isEmpty) return 'Введите название тега';
    final book = myTags;
    final other = book.idOfName(n);
    if (other != null && !book.groupOf(id).contains(other)) return 'Тег #$n уже есть';
    setMeta({'u:$m': {for (final g in book.groupOf(id)) 'tg:$g': n}});
    return null;
  }

  void deleteTag(String id) {
    final m = me;
    if (m == null) return;
    final group = myTags.groupOf(id);
    setMeta({
      'u:$m': {
        for (final g in group) 'tg:$g': '',
        for (final g in group) 'ts:$g': '',
      }
    });
    final token = tagPinToken(id);
    if (pinned.contains(token)) setPinned([for (final p in pinned) if (p != token) p]);
  }

  /// Тег показан в левой панели (закреплённые теги показываются там всегда)
  bool isTagInSidebar(String id) => me != null && data.edits['u:$me']?['ts:$id'] == '1';

  void setTagInSidebar(String id, bool on) {
    final m = me;
    if (m == null) return;
    setMeta({'u:$m': {'ts:$id': on ? '1' : ''}});
  }

  bool isTagPinned(String id) => pinned.contains(tagPinToken(id));

  /// Теги для левой панели: показанные вручную и закреплённые
  List<TagInfo> get sidebarTags {
    final pins = pinned.toSet();
    return [for (final t in myTags.all) if (isTagInSidebar(t.id) || pins.contains(tagPinToken(t.id))) t];
  }

  /// Новый плейлист из треков тега; возвращает его id (пусто — тег пуст)
  String playlistFromTag(String owner, String tagId) {
    final book = tagBookOf(owner);
    final name = book.nameOf(tagId);
    final tracks = tagTracks(owner, tagId);
    if (name == null || tracks.isEmpty) return '';
    final title = name[0].toUpperCase() + name.substring(1);
    return createPlaylist(title, [for (final t in tracks) t.id]);
  }

  /// Чужой тег — себе: создаёт такой же у меня и вешает его на те же треки
  String copyTagFrom(String owner, String tagId) {
    final book = tagBookOf(owner);
    final name = book.nameOf(tagId);
    if (name == null) return '';
    final ids = ensureTags([name]);
    if (ids.isEmpty) return '';
    setTagsOn([for (final t in tagTracks(owner, tagId)) t.id], {ids.first: true});
    return ids.first;
  }

  /// Существующие, не скрытые треки тега: свежеотмеченные сверху
  List<Track> tagTracks(String email, String tagId) {
    final book = tagBookOf(email);
    final list = [...book.tracksOf(tagId)]..sort((a, b) => b.$2.compareTo(a.$2));
    return [
      for (final e in list)
        if (data.tracks[e.$1] != null && !data.hidden.contains(e.$1)) data.tracks[e.$1]!,
    ];
  }

  int tagCount(String email, String tagId) =>
      tagBookOf(email).count(tagId, (id) => data.tracks[id] != null && !data.hidden.contains(id));
}

// ---------- поиск: «#рок #вечер nirvana», «#рок | #джаз», «-#рок» ----------

class TagQuery {
  /// Имена тегов, которые должны быть (как набраны: последний может быть недописан)
  final List<String> include;

  /// Имена после «-#»: такие теги у трека быть не должны
  final List<String> exclude;

  /// Между тегами стоит «|»: достаточно любого из них (иначе нужны все)
  final bool any;

  /// Обычный текст запроса (без тегов)
  final String text;

  const TagQuery(this.include, this.exclude, this.any, this.text);

  bool get active => include.isNotEmpty || exclude.isNotEmpty;
}

TagQuery parseTagQuery(String raw) {
  final inc = <String>[];
  final exc = <String>[];
  final words = <String>[];
  var any = false;
  for (final tok in raw.trim().split(RegExp(r'\s+'))) {
    if (tok.isEmpty) continue;
    if (tok == '|') {
      any = true;
    } else if (tok.startsWith('-#')) {
      final n = cleanTagName(tok.substring(2));
      if (n.isNotEmpty) exc.add(n);
    } else if (tok.startsWith('#')) {
      // «#рок|#джаз» без пробелов: «|» внутри слова тоже значит ИЛИ
      if (tok.contains('|')) any = true;
      for (final part in tok.split('|')) {
        final n = cleanTagName(part);
        if (n.isNotEmpty) inc.add(n);
      }
    } else {
      words.add(tok);
    }
  }
  return TagQuery(inc, exc, any, words.join(' '));
}

/// Теги, которые значит набранное имя: точное совпадение, а если такого нет — все, что на него начинаются
Set<String> _tagIdsFor(TagBook book, String name) {
  final exact = book.idOfName(name);
  if (exact != null) return {exact};
  return {for (final t in book.all) if (t.name.startsWith(name)) t.id};
}

/// Проверка трека по тегам запроса; null — в запросе тегов нет
bool Function(Track)? tagFilterFor(TagBook book, TagQuery q) {
  if (!q.active) return null;
  final inc = [for (final n in q.include) _tagIdsFor(book, n)];
  final exc = <String>{for (final n in q.exclude) ..._tagIdsFor(book, n)};
  return (Track t) {
    final have = book.timesOf(t.id);
    if (exc.isNotEmpty && have.keys.any(exc.contains)) return false;
    if (inc.isEmpty) return true;
    bool hit(Set<String> g) => g.any(have.containsKey);
    return q.any ? inc.any(hit) : inc.every(hit);
  };
}
