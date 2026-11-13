import 'package:flutter/material.dart';

import '../app.dart';
import '../core/library.dart' show LibraryController;
import '../core/models.dart';
import '../core/share_link.dart';
import '../core/track_tags.dart';
import 'device_export_ui.dart';
import 'glass_popup.dart';
import 'share_dialog.dart';
import 'shell.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'widgets.dart';

/// Обложка тега: «#» на стеклянной плитке, без картинок
class TagMark extends StatelessWidget {
  final double size;
  final double radius;
  const TagMark({super.key, required this.size, this.radius = 10});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [C.accent.withValues(alpha: 0.30), C.accent.withValues(alpha: 0.08)],
            ),
            border: Border.all(color: C.accent.withValues(alpha: 0.35)),
          ),
          child: Center(child: Icon(Icons.tag_rounded, size: size * 0.46, color: C.accent)),
        ),
      );
}

/// Страница тега: все его треки, свежеотмеченные сверху. [id] — свой тег или «почта|id» (тег, которым поделились)
class TagPage extends StatelessWidget {
  final String id;
  final bool compact;
  const TagPage({super.key, required this.id, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.lib, app.cache]),
      builder: (context, _) {
        final lib = app.lib;
        final key = parseTagKey(id, lib.me);
        final book = lib.tagBookOf(key.owner);
        final name = book.nameOf(key.id);
        if (name == null) {
          return const EmptyState(icon: Icons.tag_rounded, title: 'Такого тега нет', text: 'Его удалили или переименовали у владельца.');
        }
        final mine = key.owner == lib.me;
        final main = book.groupOf(key.id).first;
        final tracks = lib.tagTracks(key.owner, main);
        return TracksPage(
          title: '#$name',
          subtitleWidget: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(mine ? 'Ваш тег' : 'Тег друга: ', style: const TextStyle(color: C.muted, fontSize: 15)),
            if (!mine) UserLink(key.owner),
            if (tracks.isNotEmpty) Text(' · ${countTracks(tracks.length)}', style: const TextStyle(color: C.muted, fontSize: 15)),
          ]),
          image: TagMark(size: compact ? 120 : 176, radius: 14),
          tracks: tracks,
          compact: compact,
          actions: [
            OutlinedButton.icon(
              onPressed: tracks.isEmpty
                  ? null
                  : () {
                      final pl = lib.playlistFromTag(key.owner, main);
                      if (pl.isEmpty) return;
                      lib.messages.add('Плейлист создан: ${countTracks(tracks.length)}');
                      NavScope.of(context).go(Nav('playlist', pl));
                    },
              icon: const Icon(Icons.playlist_add_rounded, size: 18),
              label: const Text('Сделать плейлист'),
            ),
            if (mine)
              OfflineButton(
                on: app.cache.isTagOffline(main),
                tracks: tracks,
                onChanged: (v) => app.cache.setTagOffline(main, v),
              )
            else
              OutlinedButton.icon(
                onPressed: () {
                  final own = lib.copyTagFrom(key.owner, main);
                  if (own.isEmpty) return;
                  lib.messages.add('Тег #$name теперь и у вас');
                  NavScope.of(context).go(Nav('tag', own));
                },
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: const Text('Сохранить себе'),
              ),
            if (mine)
              GlassMenuButton<String>(
                tooltip: 'Ещё',
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (v) => _tagAction(context, v, main, name, tracks),
                itemBuilder: (_) => tagMenuItems(lib, main),
              ),
          ],
          empty: const EmptyState(
            icon: Icons.tag_rounded,
            title: 'У тега пока нет треков',
            text: 'Нажмите правой кнопкой на треке и выберите «Теги…», либо наведите на строку трека и нажмите «+» в столбце «Теги».',
          ),
        );
      },
    );
  }
}

/// Пункты меню тега: страница тега, плитка в «Коллекции» и строка в левой панели
List<PopupMenuEntry<String>> tagMenuItems(LibraryController lib, String tagId, {bool withPlay = false}) {
  final pinned = lib.isTagPinned(tagId);
  final side = lib.isTagInSidebar(tagId);
  return [
    if (withPlay) ...const [
      PopupMenuItem(value: 'play', child: Text('Слушать')),
      PopupMenuItem(value: 'shuffle', child: Text('Вперемешку')),
      PopupMenuDivider(),
    ],
    const PopupMenuItem(value: 'rename', child: Text('Переименовать…')),
    PopupMenuItem(value: 'pin', child: Text(pinned ? 'Открепить' : 'Закрепить')),
    PopupMenuItem(value: 'side', child: Text(side ? 'Убрать из боковой панели' : 'В боковую панель')),
    const PopupMenuItem(value: 'playlist', child: Text('Сделать плейлист')),
    const PopupMenuItem(value: 'share', child: Text('Поделиться…')),
    const PopupMenuItem(value: 'export', child: Text('Скачать на устройство')),
    const PopupMenuDivider(),
    const PopupMenuItem(value: 'delete', child: Text('Удалить тег', style: TextStyle(color: C.danger))),
  ];
}

/// Правый клик по тегу (плитка «Коллекции», левая панель)
Future<void> showTagMenu(BuildContext context, Offset at, String tagId) async {
  final app = Services.of(context);
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final name = app.lib.myTags.nameOf(tagId);
  if (name == null) return;
  final v = await showGlassMenu<String>(
    context: context,
    position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
    items: tagMenuItems(app.lib, tagId, withPlay: true),
  );
  if (v == null || !context.mounted) return;
  await _tagAction(context, v, tagId, name, app.lib.tagTracks(app.lib.me ?? '', tagId));
}

Future<void> _tagAction(BuildContext context, String v, String tagId, String name, List<Track> tracks) async {
  final app = Services.of(context);
  final lib = app.lib;
  switch (v) {
    case 'play':
    case 'shuffle':
      if (tracks.isEmpty) {
        lib.messages.add('У этого тега пока нет треков');
        return;
      }
      final shuffle = v == 'shuffle';
      if (app.player.shuffle != shuffle) app.player.toggleShuffle();
      app.player.playTracks(tracks, shuffle ? DateTime.now().microsecond % tracks.length : 0);
    case 'rename':
      await renameTagDialog(context, tagId);
    case 'pin':
      lib.togglePinToken([tagPinToken(tagId)]);
    case 'side':
      lib.setTagInSidebar(tagId, !lib.isTagInSidebar(tagId));
    case 'playlist':
      if (tracks.isEmpty) {
        lib.messages.add('У этого тега пока нет треков');
        return;
      }
      final nav = NavScope.of(context);
      final pl = lib.playlistFromTag(lib.me ?? '', tagId);
      if (pl.isNotEmpty) {
        lib.messages.add('Плейлист создан: ${countTracks(tracks.length)}');
        nav.go(Nav('playlist', pl));
      }
    case 'share':
      await showShareSubjectDialog(context, ShareSubject(ShareKind.tag, tagShareKey(lib.me ?? '', tagId), '#$name'));
    case 'export':
      await exportToDevice(context, List<Track>.of(tracks), folderName: name, numbered: false);
    case 'delete':
      final nav = NavScope.of(context);
      final here = nav.value.kind == 'tag';
      final ok = await confirm(context,
          title: 'Удалить тег #$name?',
          text: 'Тег снимется со всех треков (${countTracks(tracks.length)}). Сами треки останутся в библиотеке.',
          action: 'Удалить');
      if (!ok) return;
      if (here) nav.go(const Nav('collection'));
      lib.deleteTag(tagId);
      lib.messages.add('Тег #$name удалён');
  }
}

/// Переименование: треки остаются при теге, потому что связаны с ним по id
Future<void> renameTagDialog(BuildContext context, String tagId) async {
  final lib = Services.of(context).lib;
  final old = lib.myTags.nameOf(tagId);
  if (old == null) return;
  final ctrl = TextEditingController(text: old);
  String? error;
  await showGlassDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        void save() {
          final err = lib.renameTag(tagId, ctrl.text);
          if (err == null) {
            Navigator.pop(ctx);
          } else {
            setState(() => error = err);
          }
        }

        return AlertDialog(
          title: Text('Переименовать тег', style: display(18)),
          content: SizedBox(
            width: 360,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: kTagMaxLen,
              decoration: InputDecoration(hintText: 'Название тега', counterText: '', errorText: error, prefixIcon: const Icon(Icons.tag_rounded, size: 18)),
              onChanged: (_) => setState(() => error = null),
              onSubmitted: (_) => save(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: C.muted))),
            FilledButton(onPressed: save, child: const Text('Переименовать')),
          ],
        );
      },
    ),
  );
}

/// «Новый тег» в «Коллекции»: можно назвать сразу несколько через пробел
Future<void> newTagFlow(BuildContext context) async {
  final app = Services.of(context);
  final text = await askText(context, title: 'Новый тег', action: 'Создать', hint: 'Название. Несколько тегов — через пробел');
  if (text == null || text.isEmpty) return;
  final names = splitTagNames(text);
  if (names.isEmpty) return;
  final ids = app.lib.ensureTags(names);
  if (ids.length == 1 && context.mounted) NavScope.of(context).go(Nav('tag', ids.first));
}
