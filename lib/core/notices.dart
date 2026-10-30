// Уведомления «Вам»: кто-то добавил загруженный вами трек в любимое или плейлист, или поделился с вами треком.
// Источник — события в личных файлах друзей (cave-data/user-<почта>.json), поэтому здесь только разбор таких событий.

enum NoticeKind { like, addToPlaylist, share }

class Notice {
  final NoticeKind kind;
  final String from; // почта того, кто это сделал
  final DateTime at;
  final List<String> trackIds;

  /// Название плейлиста; только если плейлист открытый, иначе null
  final String? playlist;

  /// Подпись к «поделился»
  final String? note;
  const Notice(this.kind, this.from, this.at, this.trackIds, {this.playlist, this.note});

  /// Устойчивый ключ: одно и то же событие после каждого опроса получает тот же
  String get id => '${kind.name}|$from|${at.toUtc().toIso8601String()}';
}

/// Сколько треков кладём в одно событие «добавил в плейлист» (чтобы не раздувать файл статуса)
const maxAddedTracksInEvent = 40;

/// Выбирает из событий друзей те, что касаются [me]. Свои события пропускаются.
/// [uploaderOf] — кто загрузил трек (почта; пусто, если неизвестно). Новые сверху.
List<Notice> collectNotices({
  required String me,
  required Iterable<(String email, DateTime at, Map<String, dynamic> data)> events,
  required String Function(String trackId) uploaderOf,
}) {
  if (me.isEmpty) return const [];
  final out = <Notice>[];
  for (final (email, at, d) in events) {
    if (email == me) continue;
    switch ('${d['k']}') {
      case 'like':
        final id = '${d['track']}';
        if (uploaderOf(id) == me) out.add(Notice(NoticeKind.like, email, at, [id]));
      case 'addpl':
        final mine = [
          for (final x in (d['tracks'] as List? ?? const []))
            if (uploaderOf('$x') == me) '$x'
        ];
        if (mine.isNotEmpty) {
          final name = d['name'];
          out.add(Notice(NoticeKind.addToPlaylist, email, at, mine, playlist: name is String && name.isNotEmpty ? name : null));
        }
      case 'share':
        final to = [for (final x in (d['to'] as List? ?? const [])) '$x'];
        if (to.contains(me) && d['track'] != null) {
          final note = '${d['note'] ?? ''}'.trim();
          out.add(Notice(NoticeKind.share, email, at, ['${d['track']}'], note: note.isEmpty ? null : note));
        }
    }
  }
  out.sort((a, b) => b.at.compareTo(a.at));
  return out;
}

/// Только то, что новее отметки [seen] (ISO-время последнего уже показанного). Без отметки — ничего:
/// при первом запуске старые события уведомлениями не сыплются.
List<Notice> freshNotices(List<Notice> all, String? seen) {
  final since = seen == null ? null : DateTime.tryParse(seen);
  if (since == null) return const [];
  return [for (final n in all) if (n.at.isAfter(since)) n];
}

/// Текст уведомления. [label] — «Название — Исполнитель» для трека, [title] — только название
String noticeText(Notice n, {required String who, required String Function(String id) title, required String Function(String id) label}) {
  final first = n.trackIds.first;
  switch (n.kind) {
    case NoticeKind.like:
      return '$who добавил(а) «${title(first)}» в любимое';
    case NoticeKind.addToPlaylist:
      final where = n.playlist == null ? 'в плейлист' : 'в плейлист «${n.playlist}»';
      return n.trackIds.length == 1
          ? '$who добавил(а) «${title(first)}» $where'
          : '$who добавил(а) ваших треков: ${n.trackIds.length} $where';
    case NoticeKind.share:
      return '$who поделился(ась): ${label(first)}';
  }
}
