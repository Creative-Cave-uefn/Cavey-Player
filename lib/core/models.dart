// Общая библиотека: хранится одним файлом library.json в папке «Cave Player» на Диске.
// Изменения записываются как операции: при сохранении приложение скачивает
// свежую версию файла, применяет свои операции поверх и загружает обратно.
// Так правки двух друзей одновременно не затирают друг друга.

import 'tags.dart';

class Source {
  final String id;
  String name;
  final String addedBy;
  final int addedAt;
  Source({required this.id, required this.name, required this.addedBy, required this.addedAt});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'by': addedBy, 'at': addedAt};
  static Source fromJson(Map j) => Source(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        addedBy: (j['by'] as String?) ?? '',
        addedAt: (j['at'] as num?)?.toInt() ?? 0,
      );
}

// Реальный сценический псевдоним с запятой: нельзя делить его на Tyler / The Creator.
final _tylerCreator = RegExp(r'\btyler\s*,?\s*the\s+creator\b', caseSensitive: false);
const _tylerCreatorToken = '\u0002cavey-tyler-creator\u0002';

/// Единое написание артиста для показа и группировки: теги из разных
/// источников часто используют Tyler The Creator и Tyler, The Creator.
String canonicalArtistName(String raw) =>
    raw.trim().replaceAll(_tylerCreator, 'Tyler, The Creator');

// Разделители соавторов в поле «исполнитель»: «A, B», «A feat. B», «A & B», «A x B».
// «&» и «x» — только с пробелами вокруг, чтобы не резать «AC/DC» и «A&B».
final _artistSep = RegExp(
  r'\s*(?:,|;|\s/\s|\s&\s|\s(?:feat\.?|ft\.?|featuring|при\s+уч\.?|x|×|vs\.?)\s)\s*',
  caseSensitive: false,
);

// Соавторы в названии: «Песня (feat. B, C)», «Песня [ft. B]»
final _featInTitle = RegExp(r'[\(\[]\s*(?:feat\.?|ft\.?|featuring|при\s+уч\.?)\s+([^\)\]]+)[\)\]]', caseSensitive: false);

/// Отдельные исполнители трека: из поля «исполнитель» и из «(feat. …)» в названии.
/// Повторы убираются без учёта регистра, порядок как в тегах.
List<String> splitArtists(String artist, [String title = '']) {
  final out = <String>[];
  final seen = <String>{};
  void add(String raw) {
    // Temporarily protect the comma inside this artist name. Other comma-
    // separated collaborations still work: «Tyler, The Creator, Kali Uchis».
    final protected = raw.replaceAll(_tylerCreator, _tylerCreatorToken);
    for (final part in protected.split(_artistSep)) {
      final name = canonicalArtistName(part.replaceAll(
          _tylerCreatorToken, 'Tyler, The Creator'));
      if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
      out.add(name);
    }
  }

  add(artist);
  for (final m in _featInTitle.allMatches(title)) {
    add(m.group(1)!);
  }
  return out;
}

class Track {
  final String id;
  final String source;
  final String title;
  final String artist;
  final String album;
  final String albumArtist;
  final int? no;

  /// Номер диска из тегов (TPOS / DISCNUMBER); null — не указан, то есть один диск
  final int? disc;
  final String year;
  final PicRef? pic; // обложка внутри файла
  final String? cover; // cover.jpg рядом с файлом
  final String modified;
  final int size;
  final String md5; // контрольная сумма файла; пусто у старых записей, пока скан не заполнит
  final String by; // кто загрузил файл на Диск
  final String path; // папки внутри источника
  final String added; // когда файл появился на Диске

  /// Когда загружен (по часам брокера); у старых записей пусто — берётся [added]
  final String uploadedAt;

  /// Откуда трек: deezer, soulseek, youtube, bandcamp, manual; у старых записей пусто
  final String uploadSource;

  // Эти поля приходят не из файла, а из общих ручных правок (edits): старые версии
  // приложения их не знают, но при сохранении библиотеки не теряют
  int? durationMs; // длительность трека
  String? customCover; // id картинки в папке covers на Диске — своя обложка трека

  Track({
    required this.id,
    required this.source,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumArtist,
    required this.no,
    this.disc,
    required this.year,
    required this.pic,
    required this.cover,
    required this.modified,
    required this.size,
    this.md5 = '',
    required this.by,
    required this.path,
    this.added = '',
    this.uploadedAt = '',
    this.uploadSource = '',
  });

  String get displayArtist => artist.isNotEmpty
      ? canonicalArtistName(artist)
      : 'Неизвестный исполнитель';

  /// Каждый исполнитель отдельно (для страниц исполнителей и ссылок)
  late final List<String> artists = artist.isEmpty ? const ['Неизвестный исполнитель'] : splitArtists(artist, title);
  String get displayAlbum => album.isNotEmpty ? album : (path.isNotEmpty ? path.split('/').last : 'Без альбома');
  String get albumKey =>
      '${canonicalArtistName(albumArtist.isNotEmpty ? albumArtist : artist).toLowerCase()}\u0001${displayAlbum.toLowerCase()}';

  /// Ключ альбома, в который трек попадёт после правки исполнителя или альбома
  String albumKeyWith({String? newArtist, String? newAlbum, String? newAlbumArtist}) {
    final a = newArtist ?? artist;
    final al = newAlbum ?? album;
    final aa = newAlbumArtist ?? albumArtist;
    final shown = al.isNotEmpty ? al : (path.isNotEmpty ? path.split('/').last : 'Без альбома');
    return '${canonicalArtistName(aa.isNotEmpty ? aa : a).toLowerCase()}\u0001${shown.toLowerCase()}';
  }

  bool get hasCover => pic != null || cover != null || customCover != null;

  Map<String, dynamic> toJson() => {
        's': source,
        't': title,
        if (artist.isNotEmpty) 'a': artist,
        if (album.isNotEmpty) 'al': album,
        if (albumArtist.isNotEmpty) 'aa': albumArtist,
        if (no != null) 'n': no,
        if (disc != null) 'dn': disc,
        if (year.isNotEmpty) 'y': year,
        if (pic != null) 'p': [pic!.offset, pic!.length, pic!.mime],
        if (cover != null) 'c': cover,
        'm': modified,
        'sz': size,
        if (md5.isNotEmpty) 'md5': md5,
        if (by.isNotEmpty) 'by': by,
        if (path.isNotEmpty) 'path': path,
        if (added.isNotEmpty) 'ca': added,
        if (uploadedAt.isNotEmpty) 'ua': uploadedAt,
        if (uploadSource.isNotEmpty) 'us': uploadSource,
      };

  static Track fromJson(String id, Map j) {
    PicRef? pic;
    final p = j['p'];
    if (p is List && p.length == 3) pic = PicRef((p[0] as num).toInt(), (p[1] as num).toInt(), '${p[2]}');
    return Track(
      id: id,
      source: (j['s'] as String?) ?? '',
      title: (j['t'] as String?) ?? '',
      artist: (j['a'] as String?) ?? '',
      album: (j['al'] as String?) ?? '',
      albumArtist: (j['aa'] as String?) ?? '',
      no: (j['n'] as num?)?.toInt(),
      disc: (j['dn'] as num?)?.toInt(),
      year: (j['y'] as String?) ?? '',
      pic: pic,
      cover: j['c'] as String?,
      modified: (j['m'] as String?) ?? '',
      size: (j['sz'] as num?)?.toInt() ?? 0,
      md5: (j['md5'] as String?) ?? '',
      by: (j['by'] as String?) ?? '',
      path: (j['path'] as String?) ?? '',
      added: (j['ca'] as String?) ?? '',
      uploadedAt: (j['ua'] as String?) ?? '',
      uploadSource: (j['us'] as String?) ?? '',
    );
  }
}

class Playlist {
  final String id;
  String name;
  final String by;
  final int createdAt;
  final List<String> items;
  Playlist({required this.id, required this.name, required this.by, required this.createdAt, required this.items});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'by': by, 'at': createdAt, 'items': items};
  static Playlist fromJson(Map j) => Playlist(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Плейлист',
        by: (j['by'] as String?) ?? '',
        createdAt: (j['at'] as num?)?.toInt() ?? 0,
        items: [for (final x in (j['items'] as List? ?? const [])) '$x'],
      );
}

class LibraryData {
  final List<Source> sources = [];
  final Map<String, Track> tracks = {};
  final List<Playlist> playlists = [];
  final Map<String, Set<String>> likes = {}; // trackId → кто лайкнул

  /// Когда поставлен лайк: «trackId|почта» → мс. Есть только у лайков, поставленных с версии 0.2.250; у старых даты нет
  final Map<String, int> likeTimes = {};
  final Map<String, String> members = {}; // email → имя
  final Map<String, Map<String, String>> edits = {}; // ручные правки тегов

  /// IDs of recently committed operations. A remote snapshot records which
  /// edits it contains, so peers can recover an edit lost by a stale writer.
  /// Bounded to avoid growing library.json indefinitely.
  final Map<String, int> appliedOps = {};
  final Set<String> hidden = {}; // скрытые треки (например, дубликаты)

  /// Объединённые дубликаты: id скрытой копии → id той, что осталась.
  /// По нему старые ссылки (лайки, плейлисты, прослушивания) ведут на оставшуюся копию
  final Map<String, String> merged = {};

  /// Удалённые файлы: id → почта владельца. Сканирование их не возвращает,
  /// а приложение владельца удаляет файл с Диска и снимает отметку
  final Map<String, String> deleted = {};

  /// Кто записал удаление: id → почта. Если не владелец файла, владелец сначала подтверждает (А3)
  final Map<String, String> deletedBy = {};

  /// Названия удалённых треков для окна подтверждения: id → «исполнитель — название»
  final Map<String, String> deletedName = {};

  /// Подробности удаления для окна подтверждения у загрузившего: id → {
  ///   'k': причина (dup, bad, tags, other), 'note': комментарий, 't': снимок трека (с обложкой),
  ///   'keep': {'id', 't'} — какая копия остаётся (для дубликатов) }
  final Map<String, Map<String, dynamic>> deletedInfo = {};

  /// Куда ведёт id после объединений (цепочки тоже)
  String resolve(String id) {
    var cur = id;
    for (var i = 0; i < 10; i++) {
      final next = merged[cur];
      if (next == null || next == cur) return cur;
      cur = next;
    }
    return cur;
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'sources': sources.map((s) => s.toJson()).toList(),
        'tracks': tracks.map((k, v) => MapEntry(k, v.toJson())),
        'playlists': playlists.map((p) => p.toJson()).toList(),
        'likes': likes.map((k, v) => MapEntry(k, v.toList())),
        if (likeTimes.isNotEmpty) 'lt': likeTimes,
        'members': members,
        'edits': edits,
        if (appliedOps.isNotEmpty) 'appliedOps': appliedOps,
        'hidden': hidden.toList(),
        if (merged.isNotEmpty) 'merged': merged,
        if (deleted.isNotEmpty) 'deleted': deleted,
        if (deletedBy.isNotEmpty) 'deletedBy': deletedBy,
        if (deletedName.isNotEmpty) 'deletedName': deletedName,
        if (deletedInfo.isNotEmpty) 'deletedInfo': deletedInfo,
      };

  static LibraryData fromJson(dynamic j) {
    final d = LibraryData();
    if (j is! Map) return d;
    for (final s in (j['sources'] as List? ?? const [])) {
      if (s is Map) d.sources.add(Source.fromJson(s));
    }
    final t = j['tracks'];
    if (t is Map) {
      t.forEach((k, v) {
        if (v is Map) d.tracks['$k'] = Track.fromJson('$k', v);
      });
    }
    for (final p in (j['playlists'] as List? ?? const [])) {
      if (p is Map) d.playlists.add(Playlist.fromJson(p));
    }
    final l = j['likes'];
    if (l is Map) {
      l.forEach((k, v) {
        if (v is List && v.isNotEmpty) d.likes['$k'] = {for (final e in v) '$e'};
      });
    }
    final lt = j['lt'];
    if (lt is Map) {
      lt.forEach((k, v) {
        if (v is num) d.likeTimes['$k'] = v.toInt();
      });
    }
    final m = j['members'];
    if (m is Map) m.forEach((k, v) => d.members['$k'] = '$v');
    final operations = j['appliedOps'];
    if (operations is Map) {
      final cutoff = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
      for (final entry in operations.entries) {
        final time = entry.value;
        if (time is num && time.toInt() >= cutoff) {
          d.appliedOps['${entry.key}'] = time.toInt();
        }
      }
    }
    final e = j['edits'];
    if (e is Map) {
      e.forEach((k, v) {
        if (v is Map) d.edits['$k'] = v.map((a, b) => MapEntry('$a', '$b'));
      });
    }
    for (final h in (j['hidden'] as List? ?? const [])) {
      d.hidden.add('$h');
    }
    final mg = j['merged'];
    if (mg is Map) mg.forEach((k, v) => d.merged['$k'] = '$v');
    final del = j['deleted'];
    if (del is Map) del.forEach((k, v) => d.deleted['$k'] = '$v');
    final delBy = j['deletedBy'];
    if (delBy is Map) delBy.forEach((k, v) => d.deletedBy['$k'] = '$v');
    final delName = j['deletedName'];
    if (delName is Map) delName.forEach((k, v) => d.deletedName['$k'] = '$v');
    final delInfo = j['deletedInfo'];
    if (delInfo is Map) {
      delInfo.forEach((k, v) {
        if (v is Map) d.deletedInfo['$k'] = Map<String, dynamic>.from(v);
      });
    }
    for (final id in d.edits.keys) {
      d._overlay(id);
    }
    return d;
  }

  LibraryData clone() => LibraryData.fromJson(toJson());

  /// Применяет одну операцию. Операции идемпотентны: повтор ничего не ломает.
  void apply(Map<String, dynamic> op) {
    final id = op['oid'];
    if (id is String && id.isNotEmpty && appliedOps.containsKey(id)) return;
    switch (op['op']) {
      case 'addSource':
        {
          final s = Source.fromJson(op['source'] as Map);
          if (!sources.any((x) => x.id == s.id)) sources.add(s);
        }
      case 'renameSource':
        for (final s in sources) {
          if (s.id == op['id']) s.name = op['name'] as String;
        }
      case 'removeSource':
        {
          final id = op['id'];
          sources.removeWhere((s) => s.id == id);
          tracks.removeWhere((_, t) => t.source == id);
        }
      case 'upsertTracks':
        (op['tracks'] as Map).forEach((k, v) {
          if (deleted.containsKey('$k')) return; // уже удалён — не возвращаем
          tracks['$k'] = Track.fromJson('$k', v as Map);
          _overlay('$k');
        });
      case 'removeTracks':
        for (final id in (op['ids'] as List)) {
          tracks.remove(id);
        }
      case 'members':
        (op['m'] as Map).forEach((k, v) => members['$k'] = '$v');
      case 'createPlaylist':
        {
          final p = Playlist.fromJson(op['playlist'] as Map);
          if (!playlists.any((x) => x.id == p.id)) playlists.add(p);
        }
      case 'renamePlaylist':
        for (final p in playlists) {
          if (p.id == op['id']) p.name = op['name'] as String;
        }
      case 'deletePlaylist':
        playlists.removeWhere((p) => p.id == op['id']);
      case 'addToPlaylist':
        for (final p in playlists) {
          if (p.id == op['id']) {
            for (final t in (op['items'] as List)) {
              final id = resolve('$t');
              if (p.items.contains(id)) continue;
              p.items.add(id);
              // Когда трек попал в плейлист — в edits, чтобы старые версии приложения это не стирали
              final at = op['at'];
              if (at != null) edits['pl:${p.id}'] = {...?edits['pl:${p.id}'], 't:$id': '$at'};
            }
          }
        }
      case 'movePlaylistItem':
        // Ставим трек после [after] (null — в начало). Опора на соседа, а не на номер,
        // чтобы одновременные правки друзей не перемешали плейлист
        for (final p in playlists) {
          if (p.id != op['id']) continue;
          final track = resolve(op['track'] as String);
          if (!p.items.remove(track)) continue;
          final after = op['after'] as String?;
          final at = after == null ? 0 : p.items.indexOf(after) + 1;
          p.items.insert(at < 0 ? 0 : at, track);
        }
      case 'removeFromPlaylist':
        for (final p in playlists) {
          if (p.id == op['id']) {
            p.items.remove(op['track']);
            final gone = resolve(op['track'] as String);
            p.items.remove(gone);
            edits['pl:${p.id}']?.remove('t:$gone');
          }
        }
      case 'mergeTracks':
        // Дубликаты в одну копию без потерь: лайки и места в плейлистах переходят
        // на оставшуюся, остальные скрываются и запоминаются как её псевдонимы
        {
          final keep = resolve(op['keep'] as String);
          for (final raw in (op['drop'] as List)) {
            final d = '$raw';
            if (d == keep || (merged.containsKey(d) && resolve(d) == keep)) continue;
            merged[d] = keep;
            final who = likes.remove(d);
            if (who != null && who.isNotEmpty) likes.putIfAbsent(keep, () => <String>{}).addAll(who);
            for (final p in playlists) {
              final i = p.items.indexOf(d);
              if (i < 0) continue;
              if (p.items.contains(keep)) {
                p.items.removeAt(i);
              } else {
                p.items[i] = keep;
              }
            }
            final e = edits[d];
            if (e != null && edits[keep] == null) {
              edits[keep] = Map.of(e);
              _overlay(keep);
            }
            hidden.add(d);
          }
        }
      case 'deleteTracks':
        // Удаление с Диска: трек сразу пропадает у всех, файл удаляет приложение владельца
        (op['ids'] as Map).forEach((k, v) {
          final id = '$k';
          deleted[id] = '$v';
          final by = op['by'];
          if (by is String && by.isNotEmpty) deletedBy[id] = by;
          final nm = (op['names'] as Map?)?['$k'];
          if (nm != null) deletedName[id] = '$nm';
          final info = (op['info'] as Map?)?['$k'];
          if (info is Map) deletedInfo[id] = Map<String, dynamic>.from(info);
          tracks.remove(id);
          hidden.remove(id);
          likes.remove(id);
          edits.remove(id);
          for (final p in playlists) {
            p.items.remove(id);
          }
        });
      case 'approveDeletion':
        // Владелец подтвердил чужое удаление своего файла
        for (final id in (op['ids'] as List)) {
          final owner = deleted['$id'];
          if (owner != null) deletedBy['$id'] = owner;
        }
      case 'purged':
        // Файл удалён с Диска — отметка больше не нужна
        for (final id in (op['ids'] as List)) {
          deleted.remove('$id');
          deletedBy.remove('$id');
          deletedName.remove('$id');
          deletedInfo.remove('$id');
        }
      case 'unmergeTrack':
        // Вернуть копию отдельным треком (лайки и плейлисты остаются на той, куда перешли)
        {
          final id = op['id'] as String;
          merged.remove(id);
          hidden.remove(id);
        }
      case 'editTrack':
        {
          final id = op['id'] as String;
          final fields = (op['fields'] as Map).map((k, v) => MapEntry('$k', '$v'));
          edits[id] = {...?edits[id], ...fields};
          _overlay(id);
        }
      case 'setMeta':
        // Правки полей пачкой: {id: {поле: значение}}. id — трек, а также
        // 'album:<ключ альбома>', 'pl:<id плейлиста>' и 'u:<почта>' для данных, не привязанных к треку
        (op['meta'] as Map).forEach((k, v) {
          final id = '$k';
          final fields = (v as Map).map((a, b) => MapEntry('$a', '$b'));
          edits[id] = {...?edits[id], ...fields};
          _overlay(id);
        });
      case 'hideTrack':
        if (op['on'] == true) {
          hidden.add(op['id'] as String);
        } else {
          hidden.remove(op['id']);
        }
      case 'like':
        {
          final id = resolve(op['id'] as String);
          final who = op['email'] as String;
          final set = likes.putIfAbsent(id, () => <String>{});
          if (op['on'] == true) {
            set.add(who);
            final ts = op['ts'];
            if (ts is num) likeTimes['$id|$who'] = ts.toInt();
          } else {
            set.remove(who);
            likeTimes.remove('$id|$who');
          }
          if (set.isEmpty) likes.remove(id);
        }
    }
    if (id is String && id.isNotEmpty) {
      appliedOps[id] = DateTime.now().millisecondsSinceEpoch;
      if (appliedOps.length > 1500) {
        final oldest = appliedOps.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        for (final e in oldest.take(appliedOps.length - 1200)) {
          appliedOps.remove(e.key);
        }
      }
    }
  }

  /// Накладывает ручные правки (название, исполнитель, альбом, длительность, обложка) поверх тегов файла
  void _overlay(String id) {
    final t = tracks[id];
    final e = edits[id];
    if (t == null || e == null) return;
    final j = t.toJson();
    for (final entry in {'t': 't', 'a': 'a', 'al': 'al', 'y': 'y', 'aa': 'aa'}.entries) {
      final v = e[entry.key];
      if (v == null) continue;
      if (v.isEmpty && entry.key != 't') {
        j.remove(entry.value);
      } else if (v.isNotEmpty) {
        j[entry.value] = v;
      }
    }
    // Canonical catalog numbers survive later rescans even when the audio
    // file's embedded tags are absent or malformed.
    for (final key in ['n', 'dn']) {
      final value = e[key];
      if (value == null) continue;
      final parsed = int.tryParse(value);
      if (parsed != null && parsed > 0) {
        j[key] = parsed;
      } else if (value.isEmpty) {
        j.remove(key);
      }
    }
    final n = Track.fromJson(id, j);
    final d = int.tryParse(e['d'] ?? '');
    n.durationMs = (d != null && d > 0) ? d : null;
    final cv = e['cv'];
    n.customCover = (cv != null && cv.isNotEmpty) ? cv : null;
    tracks[id] = n;
  }
}
