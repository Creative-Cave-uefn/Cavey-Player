import 'package:flutter/material.dart';

import '../app.dart';
import '../core/dj.dart';
import '../core/models.dart';
import '../core/radio.dart';

/// Кнопка «АвтоDJ» для любого списка треков: плейлиста, альбома, «Любимого».
/// Всё то же, что делает АвтоDJ в Mixxx, только руками и по выбранному списку.
class DjMenuButton extends StatelessWidget {
  final List<Track> tracks;

  /// Название списка: к нему добавится « · АвтоDJ» у сохранённого плейлиста
  final String name;

  const DjMenuButton({super.key, required this.tracks, this.name = ''});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final known = _known(app);
    return MenuAnchor(
      builder: (context, controller, _) => OutlinedButton.icon(
        onPressed: tracks.isEmpty ? null : () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.graphic_eq_rounded, size: 18),
        label: const Text('АвтоDJ'),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: null,
          child: Text('Темп или тональность известны у $known из ${tracks.length}'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.all_inclusive_rounded, size: 18),
          onPressed: () => playAutoDj(app, tracks),
          child: const Text('Играть с АвтоDJ, бесконечно'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.queue_music_rounded, size: 18),
          onPressed: () => playDjChain(app, tracks),
          child: const Text('Один раз, в порядке АвтоDJ'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.playlist_add_rounded, size: 18),
          onPressed: () => saveDjPlaylist(app, tracks, name),
          child: const Text('Сохранить порядок как новый плейлист'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.analytics_outlined, size: 18),
          onPressed: () => analyzeTracks(app, tracks),
          child: const Text('Разобрать темп и тональность'),
        ),
      ],
    );
  }

  int _known(AppServices app) {
    final m = app.player.mixer;
    if (m == null) return 0;
    var n = 0;
    for (final t in tracks) {
      final p = m.profileCached(t.id);
      if (p != null && (p.bpm != null || p.key != null)) n++;
    }
    return n;
  }
}

/// Сколько треков списка АвтоDJ ничего не знает (нет ни темпа, ни тональности): они идут в конце
int _unknownCount(AppServices app, List<Track> tracks) {
  var n = 0;
  for (final t in tracks) {
    if (!app.sim.song(t).known) n++;
  }
  return n;
}

void _hintUnknown(AppServices app, List<Track> tracks) {
  final n = _unknownCount(app, tracks);
  if (n == 0) return;
  app.lib.messages.add(n == tracks.length
      ? 'АвтоDJ пока не знает темп и тональность этих треков. Выберите «Разобрать темп и тональность»: подбор станет заметно лучше'
      : 'У $n из ${tracks.length} треков темп и тональность пока неизвестны: они стоят в конце. «Разобрать темп и тональность» это исправит');
}

/// Бесконечный АвтоDJ по списку: каждый следующий трек подходит предыдущему по темпу и тональности, повторов нет
Future<void> playAutoDj(AppServices app, List<Track> tracks) async {
  if (tracks.isEmpty) return;
  final f = RadioFeeder(app.lib, app.sim, pool: [for (final t in tracks) t.id], options: djOptionsOf(app.settings));
  final first = f.begin();
  if (first.isEmpty) return;
  if (app.player.shuffle) app.player.toggleShuffle();
  await app.player.playFeed(f, first);
  _hintUnknown(app, tracks);
}

/// Список один раз, но в порядке АвтоDJ: плавная цепочка от самого медленного трека
Future<void> playDjChain(AppServices app, List<Track> tracks) async {
  if (tracks.isEmpty) return;
  final ordered = djOrder(app, tracks);
  await app.player.playTracks(ordered, 0, inOrder: true);
  _hintUnknown(app, tracks);
}

/// Новый плейлист с порядком АвтоDJ; исходный не меняется (плейлисты общие, чужой порядок трогать нельзя)
void saveDjPlaylist(AppServices app, List<Track> tracks, String name) {
  if (tracks.isEmpty) return;
  final ordered = djOrder(app, tracks);
  final title = name.trim().isEmpty ? 'Плейлист · АвтоDJ' : '${name.trim()} · АвтоDJ';
  app.lib.createPlaylist(title, [for (final t in ordered) t.id]);
  app.lib.messages.add('Плейлист «$title» создан');
  _hintUnknown(app, tracks);
}

/// Ставит треки на разбор: недостающие докачиваются в кэш, потом считаются темп, доли и тональность
void analyzeTracks(AppServices app, List<Track> tracks) {
  final m = app.player.mixer;
  if (m == null) return;
  final n = m.prepareMany([for (final t in tracks) t.id]);
  app.lib.messages.add(n == 0
      ? 'Все треки списка уже разобраны'
      : 'На разбор поставлено треков: $n. Они докачиваются в кэш и разбираются по очереди, это займёт время');
}

/// Радио по очереди: к тому, что уже стоит, бесконечно добавляются похожие треки (как радио в LMS)
void toggleQueueRadio(AppServices app) {
  final p = app.player;
  final cur = p.current;
  if (cur == null) return;
  if (p.feeder is RadioFeeder) {
    p.useFeeder(null);
    return;
  }
  final seeds = [cur.id, ...p.queue.skip(p.index + 1).take(2)];
  p.useFeeder(RadioFeeder(app.lib, app.sim, seed: seeds, radio: true, options: djOptionsOf(app.settings)));
}

/// Выстраивает следующие треки очереди по темпу и тональности, начиная с играющего
void djSortQueue(AppServices app) {
  final p = app.player;
  final cur = p.current;
  if (cur == null) return;
  final upcoming = [for (final id in p.queue.skip(p.index + 1)) if (app.lib.data.tracks[id] != null) app.lib.data.tracks[id]!];
  if (upcoming.length < 2) return;
  final songs = [app.sim.song(cur), for (final t in upcoming) app.sim.song(t)];
  final ids = AutoDj.chain(songs, options: djOptionsOf(app.settings), startId: cur.id);
  p.reorderUpcoming([for (final id in ids) if (id != cur.id) id]);
  _hintUnknown(app, upcoming);
}

/// Порядок АвтоDJ для списка треков
List<Track> djOrder(AppServices app, List<Track> tracks) {
  final byId = {for (final t in tracks) t.id: t};
  final ids = AutoDj.chain([for (final t in tracks) app.sim.song(t)], options: djOptionsOf(app.settings));
  return [for (final id in ids) byId[id]!];
}
